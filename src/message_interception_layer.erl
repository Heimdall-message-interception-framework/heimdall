%%%-------------------------------------------------------------------
%%% @author fms
%%% @copyright (C) 2021, <COMPANY>
%%% @doc
%%% @end
%%%-------------------------------------------------------------------
-module(message_interception_layer).

-behaviour(gen_server).

-export([start/2]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2,
  code_change/3]).

-define(SERVER, ?MODULE).
-define(INTERVAL, 100).

-record(state, {
%%  possibly fsm_state to check protocol
  registered_nodes :: orddict:orddict(Name::atom(), pid()),
  client_nodes :: orddict:orddict(Name::atom(), pid()),
  transient_crashed_nodes = sets:new() :: sets:set(atom()),
%%  permanent_crashed_nodes = sets:new() :: sets:set(atom()),
  messages_in_transit = [] :: [{ID::any(), From::pid(), To::pid(), Msg::any()}],
  new_messages_in_transit = [],
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
  ClientNodes = lists:map(fun(Name) ->
                            {ok, Pid} = client_node:start(Name, self()),
                            {Name, Pid}
                          end,
                          ClientNames),
%%  TODO: register nodes?
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
handle_cast({bang, {From, To, Payload}}, State = #state{}) ->
  Bool_crashed = check_if_crashed(State, To),
  Bool_whitelisted = check_if_whitelisted(From, To, Payload),
  if
    Bool_crashed -> {noreply, State};  % if crashed, do also not let whitelisted trough
    Bool_whitelisted -> send_msg(State, From, To, Payload),
                        {noreply, State};
    true ->
      UpdatedMessagesInTransit = State#state.messages_in_transit ++ [{State#state.id_counter, From, To, Payload}],
      UpdatedNewMessagesInTransit = State#state.new_messages_in_transit ++ [{State#state.id_counter, From, To, Payload}],
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
%%  TODO: search in corresponding queue for ID
  [{_, F,T,M} | _] = [{ID,F,T,M} || {ID,F,T,M} <- State#state.messages_in_transit, ID == Id],
  send_msg(State, F, T, M),
%%  TODO: record the send event and ID
  UpdatedMessages = lists:filter(fun({IDt,_,_,_}) -> Id /= IDt end, State#state.messages_in_transit),
  {noreply, State#state{messages_in_transit = UpdatedMessages}};
%%
handle_cast({send_altered, {Id, From, To, New_payload}}, State = #state{}) ->
%%  TODO: search in corresponding queue for ID
  [{_,F,T,_} | _] = [{ID,F,T,M} || {ID,F,T,M} <- State#state.messages_in_transit, ID == Id],
  send_msg(State, F, T, New_payload),
%%  TODO: record the send event with changes and ID
  UpdatedMessages = lists:filter(fun({IDt,_,_,_}) -> Id /= IDt end, State#state.messages_in_transit),
  {noreply, State#state{messages_in_transit = UpdatedMessages}};
%%
handle_cast({drop, {Id, From, To}}, State = #state{}) ->
%%  omitted parameters from and to since id uniquely determines msg exchange
  UpdatedMessages = lists:filter(fun({IDt,_,_,_}) -> Id /= IDt end, State#state.messages_in_transit),
  {noreply, State#state{messages_in_transit = UpdatedMessages}};
%%
handle_cast({client_req, ClientName, Coordinator, ClientCmd}, State = #state{}) ->
%%  TODO: submit the request to be executed by one of the clients; Coordinator is the node to contact
  gen_server:cast(client_pid(State, ClientName), {client_req, ClientName, Coordinator, ClientCmd}),
%%  we do not record client request here but afterwards when forwarded
  {noreply, State};
%%
handle_cast({fwd_client_req, ClientName, Coordinator, ClientCmd}, State = #state{}) ->
  send_client_req(State, ClientName, Coordinator, ClientCmd),
%%  TODO: record the client request
  {noreply, State};
%%
handle_cast({crash_trans, {Node}}, State = #state{}) ->
  UpdatedCrashTrans = sets:add_element(Node, State#state.transient_crashed_nodes),
  UpdatedMessages = lists:filter(fun({_,_,To,_}) -> To /= Node end, State#state.messages_in_transit),
  {noreply, State#state{transient_crashed_nodes = UpdatedCrashTrans, messages_in_transit = UpdatedMessages}};
%%
handle_cast({rejoin, {Node}}, State = #state{}) ->
  UpdatedCrashTrans = sets:del_element(Node, State#state.transient_crashed_nodes),
  {noreply, State#state{transient_crashed_nodes = UpdatedCrashTrans}}.
%%handle_cast({join, Node, new_payload}, State = #state{}) ->
%%  {noreply, State};
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

node_pid(_State, Node) ->
%%  {ok, Pid} = orddict:find(Node, State#state.registered_nodes),
%%  Pid.
  Node.

client_pid(State, Node) ->
  {ok, Pid} = orddict:find(Node, State#state.client_nodes),
  Pid.

send_msg(State, From, To, Msg) ->
%%  gen_server:cast(State#state.message_sender_id, {send, node_pid(State, From), node_pid(State, To), Msg}).
  gen_server:cast(To, {message, node_pid(State, From), node_pid(State, To), Msg}).

%% TODO: merge with the one before once pids and name issues are resolved
send_client_req(State, From, To, Msg) ->
%%  gen_server:cast(State#state.message_sender_id, {send, node_pid(State, From), node_pid(State, To), Msg}).
  gen_server:cast(To, {message, client_pid(State, From), node_pid(State, To), Msg}).

restart_timer() ->
%%  could also only restart when not enabled yet and then after sched events
  erlang:send_after(?INTERVAL, self(), trigger_get_events).

check_if_whitelisted(_From, _To, _Payload) ->
%%  TODO: implemented whitelist check, currently none whitelisted
  false.

check_if_crashed(State, To) ->
  sets:is_element(To, State#state.transient_crashed_nodes).
