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
  message_collector_id :: pid(),
  message_sender_id :: pid(),
  scheduler_id :: pid()
}).

%%%===================================================================
%%% Spawning and gen_server implementation
%%%===================================================================

start(Scheduler, ClientNames) ->
  {ok, MIL} = gen_server:start_link(?MODULE, [Scheduler, ClientNames], []),
  MsgCollector = gen_server:call(MIL, get_message_collector),
  {ok, MIL, MsgCollector}.
%%  return more than that?

init([Scheduler, ClientNames]) ->
  ClientNodes = lists:map(fun(Name) ->
                            {ok, Pid} = client_node:start(Name),
                            {Name, Pid}
                          end,
                          ClientNames),
%%  TODO: register nodes?
  {ok, Pid_sender} = message_sender:start(),
  {ok, Pid_collector} = message_collector:start(self(), Pid_sender),
  {
    ok, #state{
               message_collector_id = Pid_collector,
               message_sender_id = Pid_sender,
               scheduler_id = Scheduler,
               client_nodes = ClientNodes
    }
  }.

handle_call(get_message_collector, _From, State) ->
  {reply, State#state.message_collector_id, State}.

handle_cast({start}, State = #state{}) ->
  erlang:send_after(?INTERVAL, self(), trigger_get_events),
  {noreply, State};
handle_cast({new_events, List_of_new_messages}, State = #state{}) ->
  Updated_messages_in_transit = State#state.messages_in_transit ++ List_of_new_messages,
%%  if % not a good idea to wait another round if no messages around, potentially client requests by scheduler
%%    Updated_messages_in_transit == [] -> restart_timer();
%%    Updated_messages_in_transit =:= [] ->
  gen_server:cast(State#state.scheduler_id, {new_events, List_of_new_messages}),
%%  end,
%%  TODO: record the new events
  {noreply, State#state{messages_in_transit = Updated_messages_in_transit}};
handle_cast({noop, {}}, State = #state{}) -> % use IDs here later
  restart_timer(),
  {noreply, State};
handle_cast({crash_trans, {Node}}, State = #state{}) -> % use IDs here later
  UpdatedCrashTrans = State#state.transient_crashed_nodes ++ [Node],
  restart_timer(),
  {noreply, State#state{transient_crashed_nodes = UpdatedCrashTrans}};
handle_cast({send, {Id}}, State = #state{}) -> % use IDs here later
  [{_, F,T,M} | _] = [{ID,F,T,M} || {ID,F,T,M} <- State#state.messages_in_transit, ID == Id],
  send_msg(State, F, T, M),
  logger:info("sent some message"),
%%  TODO: record the send event and ID
  UpdatedMessages = lists:filter(fun({IDt,_,_,_}) -> Id /= IDt end, State#state.messages_in_transit),
  restart_timer(),
  {noreply, State#state{messages_in_transit = UpdatedMessages}};
handle_cast({send_altered, {Id, New_payload}}, State = #state{}) ->
%%  omitted parameters from and to since id uniquely determines msg exchange
  [{_,F,T,_} | _] = [{ID,F,T,M} || {ID,F,T,M} <- State#state.messages_in_transit, ID == Id],
  send_msg(State, F, T, New_payload),
%%  TODO: record the send event with changes and ID
  UpdatedMessages = lists:filter(fun({IDt,_,_,_}) -> Id /= IDt end, State#state.messages_in_transit),
  restart_timer(),
  {noreply, State#state{messages_in_transit = UpdatedMessages}};
handle_cast({drop, {Id}}, State = #state{}) -> % use IDs here later
  UpdatedMessages = lists:filter(fun({IDt,_,_,_}) -> Id /= IDt end, State#state.messages_in_transit),
  restart_timer(),
  {noreply, State#state{messages_in_transit = UpdatedMessages}};
handle_cast({client_req, ClientName, Coordinator, ClientCmd}, State = #state{}) ->
%%  TODO: submit the request to be executed by one of the clients; Coordinator is the node to contact
  gen_server:cast(client_pid(State, ClientName), {client_req, State#state.message_collector_id, ClientName, Coordinator, ClientCmd}),
%%  TODO: record the client request
  restart_timer(),
  {noreply, State}.
%%handle_cast({join, which_one, new_payload}, State = #state{}) ->
%%  {noreply, State};
%%handle_cast({crash_transient, which_one, new_payload}, State = #state{}) ->
%%  {noreply, State};
%%handle_cast({crash_permanent, which_one, new_payload}, State = #state{}) ->
%%  {noreply, State};


handle_info(trigger_get_events, State = #state{}) ->
  gen_server:cast(State#state.message_collector_id, {get_since_last}),
%% we do not start a new timer here but after the new event was scheduled
  {noreply, State}.

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
  gen_server:cast(State#state.message_sender_id, {send, node_pid(State, From), node_pid(State, To), Msg}).

restart_timer() ->
  erlang:send_after(?INTERVAL, self(), trigger_get_events).
