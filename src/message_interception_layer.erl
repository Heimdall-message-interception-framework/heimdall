%%%-------------------------------------------------------------------
%%% @author fms
%%% @copyright (C) 2021, <COMPANY>
%%% @doc
%%% @end
%%%-------------------------------------------------------------------
-module(message_interception_layer).

-include_lib("sched_event.hrl").

-behaviour(gen_server).

-export([start/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2,
  code_change/3]).

-define(SERVER, ?MODULE).
-define(INTERVAL, 100).

-record(state, {
  registered_nodes_pid = orddict:new() :: orddict:orddict(Name::atom(), pid()),
  registered_pid_nodes = orddict:new() :: orddict:orddict(pid(), Name::atom()),
  client_nodes = orddict:new() :: orddict:orddict(Name::atom(), pid()),
  transient_crashed_nodes = sets:new() :: sets:set(atom()),
  permanent_crashed_nodes = sets:new() :: sets:set(atom()),
  messages_in_transit = orddict:new() :: orddict:orddict(FromTo::any(),
                                        queue:queue({ID::any(), Payload::any()})),
  new_messages_in_transit = [] :: [{ID::any(), From::pid(), To::pid(), Msg::any()}],
%%  scheduler_id is only used to send the new_events, we could also request these with the scheduler
  scheduler_id :: pid(),
  id_counter = 0 :: any(),
  bc_nodes = sets:new() :: sets:set(atom())
}).

%%%===================================================================
%%% Spawning and gen_server implementation
%%%===================================================================

start(Scheduler) ->
  gen_server:start_link(?MODULE, [Scheduler], []).

init([Scheduler]) ->
  {ok, #state{scheduler_id = Scheduler}}.

handle_call({all_bc_pids}, _From, State = #state{}) ->
  AllPids = lists:map(fun(Name) -> node_pid(State, Name) end, sets:to_list(State#state.bc_nodes)),
  {reply, AllPids, State};
handle_call({reg_bc_node, {NodeName}}, _From, State = #state{}) ->
  NewBcNodes = sets:add_element(NodeName, State#state.bc_nodes),
  {reply, ok, State#state{bc_nodes = NewBcNodes}};
handle_call(_Request, _From, State) ->
  {reply, ok, State}.

handle_cast({start}, State) ->
  erlang:send_after(?INTERVAL, self(), trigger_get_events),
  {noreply, State};
%%
handle_cast({register, {NodeName, NodePid, NodeClass}}, State = #state{}) ->
  NewRegisteredNodesPid = orddict:store(NodeName, NodePid, State#state.registered_nodes_pid),
  NewRegisteredPidNodes = orddict:store(NodePid, NodeName, State#state.registered_pid_nodes),
  AllOtherNames = get_all_node_names(State),
  ListNewQueues = [{{Other, NodeName}, queue:new()} || Other <- AllOtherNames] ++
                  [{{NodeName, Other}, queue:new()} || Other <- AllOtherNames],
  OrddictNewQueues = orddict:from_list(ListNewQueues),
  Fun = fun({_, _}, _, _) -> undefined end,
  NewMessageStore = orddict:merge(Fun, State#state.messages_in_transit, OrddictNewQueues),
  logger:info("registration", #{what => reg_node, name => NodeName, class => NodeClass}),
  {noreply, State#state{registered_nodes_pid = NewRegisteredNodesPid, registered_pid_nodes = NewRegisteredPidNodes,
                        messages_in_transit = NewMessageStore}};
%%
handle_cast({register_client, {ClientName}}, State = #state{}) ->
  {ok, Pid} = client_node:start(ClientName, self()),
  NewClientDict = orddict:store(ClientName, Pid, State#state.client_nodes),
  logger:info("regst_client", #{what => reg_clnt, name => ClientName}),
  {noreply, State#state{client_nodes = NewClientDict}};
%%
handle_cast({cast_msg, From, To, Message}, State = #state{}) ->
%%handle_cast({cast_msg, From, To, {Message}}, State = #state{}) ->
%%  this can be used to replay also the function calls to participants interacting (e.g. to initiate sending messages)
  FromPid = node_pid(State, From),
  ToPid = node_pid(State, To),
  logger:info("cast_msg", #{what => cast_msg, from => From, to => To, mesg => Message}),
  gen_server:cast(FromPid, {casted, ToPid, Message}),
  {noreply, State};
%%
handle_cast({bang, {FromPid, ToPid, Payload}}, State = #state{}) ->
  From = pid_node(State, FromPid),
  To = pid_node(State, ToPid),
  Bool_crashed = check_if_crashed(State, To) or check_if_crashed(State, From),
  Bool_whitelisted = check_if_whitelisted(From, To, Payload),
  if
    Bool_crashed ->
%%      still log this event for matching later on
      logger:info("rcv_crsh", #{what => rcv_crsh, id => State#state.id_counter, from => From, to => To, mesg => Payload}),
      NextID = State#state.id_counter + 1,
      {noreply, State#state{id_counter = NextID}};  % if crashed, do also not let whitelisted trough
    Bool_whitelisted -> send_msg(State, FromPid, ToPid, Payload),
                        {noreply, State};
    true ->
      QueueToUpdate = orddict:fetch({From, To}, State#state.messages_in_transit),
      UpdatedQueue = queue:in({State#state.id_counter, Payload}, QueueToUpdate),
      UpdatedMessagesInTransit = orddict:store({From, To}, UpdatedQueue, State#state.messages_in_transit),
      UpdatedNewMessagesInTransit = State#state.new_messages_in_transit ++ [{State#state.id_counter, From, To, Payload}],
      logger:info("received", #{what => received, id => State#state.id_counter, from => From, to => To, mesg => Payload}),
      NextID = State#state.id_counter + 1,
      {noreply, State#state{messages_in_transit = UpdatedMessagesInTransit,
        new_messages_in_transit = UpdatedNewMessagesInTransit,
        id_counter = NextID}}
  end;
%%
handle_cast({noop, {}}, State = #state{}) ->
  {noreply, State};
%%
handle_cast({send, {Id, From, To}}, State = #state{}) ->
  {M, Skipped, NewMessageStore} = find_message_and_get_upated_messages_in_transit(State, Id, From, To),
  send_msg(State, From, To, M),
  logger:info("snd_orig", #{what => snd_orig, id => Id, from => From, to => To, mesg => M, skipped => Skipped}),
  {noreply, State#state{messages_in_transit = NewMessageStore}};
%%
handle_cast({duplicate, {Id, From, To}}, State = #state{}) ->
  {M, Skipped} = find_message(State, Id, From, To),
  send_msg(State, From, To, M),
  logger:info("duplicat", #{what => duplicat, id => Id, from => From, to => To, mesg => M, skipped => Skipped}),
  {noreply, State};
%%
handle_cast({send_altered, {Id, From, To, New_payload}}, State = #state{}) ->
  {M, Skipped, NewMessageStore} = find_message_and_get_upated_messages_in_transit(State, Id, From, To),
  send_msg(State, From, To, New_payload),
  logger:info("snd_altr", #{what => snd_altr, id => Id, from => From, to => To, mesg => New_payload, old_mesg => M, skipped => Skipped}),
  {noreply, State#state{messages_in_transit = NewMessageStore}};
%%
handle_cast({drop, {Id, From, To}}, State = #state{}) ->
  {M, _, NewMessageStore} = find_message_and_get_upated_messages_in_transit(State, Id, From, To),
  logger:info("drop_msg", #{what => drop_msg, id => Id, from => From, to => To, mesg => M}),
%%  maybe check whether Skipped is empty and report if not
  {noreply, State#state{messages_in_transit = NewMessageStore}};
%%
handle_cast({client_req, {ClientName, Coordinator, ClientCmd}}, State = #state{}) ->
%%  TODO: once connected with riak, submit the request to be executed by one of the clients; Coordinator is the node to contact
  gen_server:cast(client_pid(State, ClientName), {client_req, ClientName, Coordinator, ClientCmd}),
  logger:info("clnt_req", #{what => clnt_req, from => ClientName, to => Coordinator, mesg => ClientCmd}),
  {noreply, State};
%%
handle_cast({fwd_client_req, {ClientName, Coordinator, ClientCmd}}, State = #state{}) ->
%%  TODO: the client command should actually be the corresponding message
%%  TODO: what about ack's / replies?
  send_client_req(State, ClientName, Coordinator, ClientCmd),
%%  logged when issued
  {noreply, State};
%%
handle_cast({crash_trans, {NodeName}}, State = #state{}) ->
  UpdatedCrashTrans = sets:add_element(NodeName, State#state.transient_crashed_nodes),
  ListQueuesToEmpty = [{Other, NodeName} || Other <- get_all_node_names(State), Other /= NodeName],
  NewMessageStore = lists:foldl(fun({From, To}, SoFar) -> orddict:store({From, To}, queue:new(), SoFar) end,
              State#state.messages_in_transit,
              ListQueuesToEmpty),
%%  in order to let a schedule replay, we do not need to log all the dropped messages due to crashes
  logger:info("trans_crs", #{what => trns_crs, name => NodeName}),
  {noreply, State#state{transient_crashed_nodes = UpdatedCrashTrans, messages_in_transit = NewMessageStore}};
%%
handle_cast({rejoin, {NodeName}}, State = #state{}) ->
%%  for transient crashes only
  UpdatedCrashTrans = sets:del_element(NodeName, State#state.transient_crashed_nodes),
  logger:info("rejoin", #{what => rejoin, name => NodeName}),
  {noreply, State#state{transient_crashed_nodes = UpdatedCrashTrans}};
handle_cast({crash_perm, {NodeName}}, State = #state{}) ->
%%  for now, we keep the outgoing channels since these are messages that were sent before (still scheduable)
  UpdatedCrashPerm = sets:add_element(NodeName, State#state.permanent_crashed_nodes),
  ListQueuesToDelete = [{Other, NodeName} || Other <- get_all_node_names(State), Other /= NodeName],
  NewMessageStore = lists:foldl(fun({From, To}, SoFar) -> orddict:erase({From, To}, SoFar) end,
    State#state.messages_in_transit,
    ListQueuesToDelete),
%%  in order to let a schedule replay, we do not need to log all the dropped messages due to crashes
  logger:info(#{what => perm_crs, name => NodeName}),
  {noreply, State#state{permanent_crashed_nodes = UpdatedCrashPerm, messages_in_transit = NewMessageStore}}.


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
  gen_server:cast(node_pid(State, To), {message, node_pid(State, From), node_pid(State, To), Msg}).

send_client_req(State, From, To, Msg) ->
  gen_server:cast(To, {message, client_pid(State, From), node_pid(State, To), Msg}).

restart_timer() ->
%%  TODO: give option for this or scheduler asks for new events themself for
  erlang:send_after(?INTERVAL, self(), trigger_get_events).

check_if_whitelisted(_From, _To, _Payload) ->
%%  TODO: implement whitelist check, currently none whitelisted
  false.

check_if_crashed(State, To) ->
  sets:is_element(To, State#state.transient_crashed_nodes) or sets:is_element(To, State#state.permanent_crashed_nodes).

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

find_message(State, Id, From, To) ->
  QueueToSearch = orddict:fetch({From, To}, State#state.messages_in_transit),
  {M, Skipped, _} = find_id_in_queue(QueueToSearch, Id),
  {M, Skipped}.

