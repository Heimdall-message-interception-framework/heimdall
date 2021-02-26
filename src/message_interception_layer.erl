%%%-------------------------------------------------------------------
%%% @author fms
%%% @copyright (C) 2021, <COMPANY>
%%% @doc
%%% @end
%%%-------------------------------------------------------------------
-module(message_interception_layer).

-include_lib("sched_event.hrl").

-behaviour(gen_server).

-export([start/2]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2,
  code_change/3]).

-define(SERVER, ?MODULE).
-define(INTERVAL, 100).

-record(state, {
%%  possibly fsm_state to check protocol
  registered_nodes_pid = orddict:new() :: orddict:orddict(Name::atom(), pid()),
  registered_pid_nodes = orddict:new() :: orddict:orddict(pid(), Name::atom()),
  client_nodes :: orddict:orddict(Name::atom(), pid()),
  transient_crashed_nodes = sets:new() :: sets:set(atom()),
%%  permanent_crashed_nodes = sets:new() :: sets:set(atom()),
  messages_in_transit = orddict:new() :: orddict:orddict(FromTo::any(),
                                        queue:queue({ID::any(), Payload::any()})),
  new_messages_in_transit = [] :: [{ID::any(), From::pid(), To::pid(), Msg::any()}],
  message_sender_id :: pid(),
  scheduler_id :: pid(),
  id_counter = 0 :: any()
}).

%%%===================================================================
%%% Spawning and gen_server implementation
%%%===================================================================

start(Scheduler, ClientNames) ->
  {ok, MIL} = gen_server:start_link(?MODULE, [Scheduler, ClientNames], []),
  {ok, MIL}.

init([Scheduler, ClientNames]) ->
  ClientNodes = orddict:from_list(
                            lists:map(fun(Name) ->
                            {ok, Pid} = client_node:start(Name, self()),
                            {Name, Pid}
                          end,
                          ClientNames)
                ),
  {ok, Pid_sender} = message_sender:start(),
  {
    ok, #state{
               message_sender_id = Pid_sender,
               scheduler_id = Scheduler,
               client_nodes = ClientNodes
    }
  }.

handle_call(_Request, _From, State = #state{}) ->
  {reply, ok, State}.

handle_cast({start}, State = #state{}) ->
  erlang:send_after(?INTERVAL, self(), trigger_get_events),
  {noreply, State};
%%
handle_cast({register, {NodeName, NodePid}}, State = #state{}) ->
  NewRegisteredNodesPid = orddict:store(NodeName, NodePid, State#state.registered_nodes_pid),
  NewRegisteredPidNodes = orddict:store(NodePid, NodeName, State#state.registered_pid_nodes),
  AllOtherNames = get_all_node_names(State),
  ListNewQueues = [{{Other, NodeName}, queue:new()} || Other <- AllOtherNames] ++
                  [{{NodeName, Other}, queue:new()} || Other <- AllOtherNames],
  OrddictNewQueues = orddict:from_list(ListNewQueues),
  Fun = fun({_, _}, _, _) -> undefined end,
  NewMessageStore = orddict:merge(Fun, State#state.messages_in_transit, OrddictNewQueues),
%%  TODO: record registration of node
  {noreply, State#state{registered_nodes_pid = NewRegisteredNodesPid, registered_pid_nodes = NewRegisteredPidNodes,
                        messages_in_transit = NewMessageStore}};
%%
handle_cast({bang, {FromPid, ToPid, Payload}}, State = #state{}) ->
  From = pid_node(State, FromPid),
  To = pid_node(State, ToPid),
  Bool_crashed = check_if_crashed(State, To),
  Bool_whitelisted = check_if_whitelisted(From, To, Payload),
  if
    Bool_crashed -> {noreply, State};  % if crashed, do also not let whitelisted trough
    Bool_whitelisted -> send_msg(State, FromPid, ToPid, Payload),
                        {noreply, State};
    true ->
      QueueToUpdate = orddict:fetch({From, To}, State#state.messages_in_transit),
      UpdatedQueue = queue:in({State#state.id_counter, Payload}, QueueToUpdate),
      UpdatedMessagesInTransit = orddict:store({From, To}, UpdatedQueue, State#state.messages_in_transit),
      UpdatedNewMessagesInTransit = State#state.new_messages_in_transit ++ [{State#state.id_counter, From, To, Payload}],
      logger:info("received", #{what => "received", id => State#state.id_counter, from => From, to => To, mesg => Payload}),
      NextID = State#state.id_counter + 1,
      {noreply, State#state{messages_in_transit = UpdatedMessagesInTransit,
        new_messages_in_transit = UpdatedNewMessagesInTransit,
        id_counter = NextID}}
  end;
%%
handle_cast({noop, {}}, State = #state{}) ->
  {noreply, State};
%%
%% for queues, having From and To would help
handle_cast({send, {Id, From, To}}, State = #state{}) ->
  {M, Skipped, NewMessageStore} = find_message_and_get_upated_messages_in_transit(State, Id, From, To),
  send_msg(State, From, To, M),
  logger:info("snd_orig", #{what => "snd_orig", id => Id, from => From, to => To, mesg => M, skipped => Skipped}),
  {noreply, State#state{messages_in_transit = NewMessageStore}};
%%
handle_cast({send_altered, {Id, From, To, New_payload}}, State = #state{}) ->
  {M, Skipped, NewMessageStore} = find_message_and_get_upated_messages_in_transit(State, Id, From, To),
  send_msg(State, From, To, New_payload),
  logger:info("snd_altr", #{what => "snd_altr", id => Id, from => From, to => To, mesg => New_payload, old_mesg => M, skipped => Skipped}),
  {noreply, State#state{messages_in_transit = NewMessageStore}};
%%
handle_cast({drop, {Id, From, To}}, State = #state{}) ->
  {M, _, NewMessageStore} = find_message_and_get_upated_messages_in_transit(State, Id, From, To),
  logger:info("drop_msg", #{what => "drop_msg", id => Id, from => From, to => To, mesg => M}),
%%  maybe check whether Skipped is empty and report if not
  {noreply, State#state{messages_in_transit = NewMessageStore}};
%%
handle_cast({client_req, ClientName, Coordinator, ClientCmd}, State = #state{}) ->
%%  TODO: once connected with riak, submit the request to be executed by one of the clients; Coordinator is the node to contact
  gen_server:cast(client_pid(State, ClientName), {client_req, ClientName, Coordinator, ClientCmd}),
  logger:info("clnt_req", #{what => "clnt_req", from => ClientName, to => Coordinator, mesg => ClientCmd}),
  {noreply, State};
%%
handle_cast({fwd_client_req, ClientName, Coordinator, ClientCmd}, State = #state{}) ->
%%  TODO: the client command should actually be the corresponding message
%%  TODO: what about ack's / replies?
  send_client_req(State, ClientName, Coordinator, ClientCmd),
%%  logged when issued
%%  logger:info("fwd_clreq", #{what => "clnt_req", from => ClientName, to => Coordinator, mesg => ClientCmd}),
  {noreply, State};
%%
handle_cast({crash_trans, {Node}}, State = #state{}) ->
  UpdatedCrashTrans = sets:add_element(Node, State#state.transient_crashed_nodes),
  ListQueuesToEmpty = [{Other, Node} || Other <- get_all_node_names(State), Other /= Node],
  NewMessageStore = lists:foldl(fun({From, To}, SoFar) -> orddict:store({From, To}, queue:new(), SoFar) end,
              State#state.messages_in_transit,
              ListQueuesToEmpty),
%%  for now, we do not log all the dropped messages
  logger:info(#{what => "trns_crs", node => Node}),
  {noreply, State#state{transient_crashed_nodes = UpdatedCrashTrans, messages_in_transit = NewMessageStore}};
%%
handle_cast({rejoin, {Node}}, State = #state{}) ->
%%  this one is used for transient crashed nodes
  UpdatedCrashTrans = sets:del_element(Node, State#state.transient_crashed_nodes),
  logger:info("rejoin", #{what => "rejoin", node => Node}),
  {noreply, State#state{transient_crashed_nodes = UpdatedCrashTrans}}.
%%handle_cast({crash_permanent, which_one, new_payload}, State = #state{}) ->
%%  {noreply, State};


handle_info(trigger_get_events, State = #state{}) ->
  gen_server:cast(State#state.scheduler_id, {new_events, State#state.new_messages_in_transit}),
  restart_timer(),
  {noreply, State#state{new_messages_in_transit = []}}.

terminate(_Reason, _State = #state{}) ->
  ok.

code_change(_OldVsn, State = #state{}, _Extra) ->
  {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

node_pid(State, Node) ->
  {ok, Pid} = orddict:find(Node, State#state.registered_nodes_pid),
  Pid.

pid_node(State, Pid) ->
  {ok, Node} = orddict:find(Pid, State#state.registered_pid_nodes),
  Node.

client_pid(State, Node) ->
  {ok, Pid} = orddict:find(Node, State#state.client_nodes),
  Pid.

send_msg(State, From, To, Msg) ->
  gen_server:cast(To, {message, node_pid(State, From), node_pid(State, To), Msg}).

send_client_req(State, From, To, Msg) ->
  gen_server:cast(To, {message, client_pid(State, From), node_pid(State, To), Msg}).

restart_timer() ->
%%  could also only restart when not enabled yet and then after sched events
  erlang:send_after(?INTERVAL, self(), trigger_get_events).

check_if_whitelisted(_From, _To, _Payload) ->
%%  TODO: implement whitelist check, currently none whitelisted
  false.

check_if_crashed(State, To) ->
  sets:is_element(To, State#state.transient_crashed_nodes).

get_all_node_names(State) ->
  orddict:fetch_keys(State#state.registered_nodes_pid).

find_id_in_queue(QueueToSearch, Id) ->
  find_id_in_queue([], QueueToSearch, Id).

find_id_in_queue(SkippedList, TailQueueToSearch, Id) ->
  {{value, {CurrentId, CurrentPayload}}, NewTailQueueToSearch} = queue:out(TailQueueToSearch),
  case CurrentId == Id  of
    true -> ReversedSkipped = lists:reverse(SkippedList),
            {CurrentPayload, ReversedSkipped, queue:join(queue:from_list(ReversedSkipped), NewTailQueueToSearch)};
%%    skipped does only contain the IDs
    false -> find_id_in_queue([CurrentId | SkippedList], NewTailQueueToSearch, Id)
  end.

find_message_and_get_upated_messages_in_transit(State, Id, From, To) ->
  QueueToSearch = orddict:fetch({From, To}, State#state.messages_in_transit),
  {M, Skipped, UpdatedQueue} = find_id_in_queue(QueueToSearch, Id),
  NewMessageStore = orddict:store({From, To}, UpdatedQueue, State#state.messages_in_transit),
  {M, Skipped, NewMessageStore}.


