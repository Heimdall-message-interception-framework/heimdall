%%%-------------------------------------------------------------------
%%% @author fms
%%% @copyright (C) 2021, <COMPANY>
%%% @doc
%%% @end
%%%-------------------------------------------------------------------
-module(message_interception_layer).

-behaviour(gen_server).

-export([start/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2,
  code_change/3]).

-define(SERVER, ?MODULE).
-define(TIMEOUT, 1000).

-record(state, {
%%  possibly fsm_state to check protocol
  registered_nodes :: orddict:orddict(Name::atom(), pid()),
  client_nodes :: orddict:orddict(Name::atom(), pid()),
  transient_crashed_nodes = sets:new() :: sets:set(atom()),
%%  permanent_crashed_nodes = sets:new() :: sets:set(atom()),
  messages_in_transit = [] :: [{From::pid(), To::pid(), Msg::any()}],
  message_collector_id :: pid(),
  message_sender_id :: pid(),
  scheduler_id :: pid()
}).

%%%===================================================================
%%% Spawning and gen_server implementation
%%%===================================================================

%%start_link() ->
%%  gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

start(ClientNames) ->
  {ok, MIL} = gen_server:start_link(?MODULE, [ClientNames], []),
  MsgCollector = gen_server:call(MIL, get_message_collector),
  {ok, MIL, MsgCollector}.
%%  return more than that?

init([ClientNames]) ->
  {ok, Pid_sender} = message_sender:start(),
  {ok, Pid_collector} = message_collector:start(self(), Pid_sender),
  {ok, Pid_scheduler} = scheduler:start(self()),
%%  ClientNodes = lists:map(fun(Name) ->
%%                            {ok, Pid} = client_node:start(self(), Name),
%%                            {Name, Pid}
%%                          end,
%%                          ClientNames),
%%  TODO: register nodes?
  {
    ok, #state{
               message_collector_id = Pid_collector,
               message_sender_id = Pid_sender,
               scheduler_id = Pid_scheduler
%%               client_nodes = ClientNodes
  }
  }.

handle_call(get_message_collector, _From, State) ->
  {reply, State#state.message_collector_id, State}.
%%handle_call(_Request, _From, State = #state{}) ->
%%  {reply, ok, State}.

handle_cast({start}, State = #state{}) ->
%%  get_new_events(),
  gen_server:cast(State#state.message_collector_id, {get_since_last}),
  {noreply, State};
handle_cast({new_events, List_of_new_messages}, State = #state{}) ->
  erlang:display(List_of_new_messages),
  Updated_messages_in_transit = State#state.messages_in_transit ++ List_of_new_messages,
%%  if Updated_messages_in_transit =:= [] ->
%%    get_new_events()
%%  end,
%%  TODO: record the new events
  gen_server:cast(State#state.scheduler_id, {new_events, List_of_new_messages}),
  {noreply, State#state{messages_in_transit = Updated_messages_in_transit}};
handle_cast({send, {From, To, Msg}}, State = #state{}) -> % use IDs here later
  [{F,T,M} | _] = [{F,T,M} || {F,T,M} <- State#state.messages_in_transit, From == F, To == T, Msg == M],
  send_msg(State, F, T, M),
%%  TODO: record the send event
  erlang:display("do we get here?"),
%%  wait for new events
%%  get_new_events(),
  {noreply, State};
handle_cast({send_altered, IDtoSend, New_payload}, State = #state{}) ->
%%  omitted parameters from and to since id uniquely determines msg exchange
  [{_,F,T,_} | _] = [{ID,F,T,M} || {ID,F,T,M} <- State#state.messages_in_transit, ID == IDtoSend],
  send_msg(State, F, T, New_payload),
%%  TODO: record the send event with changes

%%  wait for new events
%%  get_new_events(),
  {noreply, State};
handle_cast({client_req, ClientName, ClientCmd}, State = #state{}) ->
%%  TODO: submit the request to be executed by one of the clients
  gen_server:cast(client_pid(State, ClientName), {send_req, ClientCmd}),
%%  TODO: forward the client_req; we could also whitelist them
%%  TODO: record the client request
%%  get_new_events(),
  {noreply, State}.
%%handle_cast({join, which_one, new_payload}, State = #state{}) ->
%%  {noreply, State};
%%handle_cast({crash_transient, which_one, new_payload}, State = #state{}) ->
%%  {noreply, State};
%%handle_cast({crash_permanent, which_one, new_payload}, State = #state{}) ->
%%  {noreply, State};


handle_info(_Info, State = #state{}) ->
  {noreply, State}.

terminate(_Reason, _State = #state{}) ->
  ok.

code_change(_OldVsn, State = #state{}, _Extra) ->
  {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

get_new_events() ->
  erlang:display("wait for new events"),
  timer:sleep(?TIMEOUT),
  erlang:display("wait for new events ended"),
  gen_server:cast(#state.message_collector_id, {get_since_last}).

node_pid(State, Node) ->
%%  {ok, Pid} = orddict:find(Node, State#state.registered_nodes),
%%  Pid.
  Node.

client_pid(State, Node) ->
  {ok, Pid} = orddict:find(Node, State#state.client_nodes),
  Pid.

send_msg(State, From, To, Msg) ->
  gen_server:cast(State#state.message_sender_id, {send, node_pid(State, From), node_pid(State, To), Msg}).
