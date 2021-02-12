%%%-------------------------------------------------------------------
%%% @author fms
%%% @copyright (C) 2021, <COMPANY>
%%% @doc
%%% @end
%%%-------------------------------------------------------------------
-module(message_collector).

-behaviour(gen_server).

-export([start/2]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2,
  code_change/3]).

-define(SERVER, ?MODULE).

-record(state, {
  message_interception_layer_id :: pid(),
  message_sender_id :: pid(),
  messages_in_transit = [] :: [{From::pid(), To::pid(), Msg::any()}]
}).

%%%===================================================================
%%% Spawning and gen_server implementation
%%%===================================================================

%%start_link() ->
%%  gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

start(MIL, S_id) ->
  gen_server:start_link(?MODULE, [MIL, S_id], []).


init([MIL, S_id]) ->
  {ok, #state{message_interception_layer_id = MIL, message_sender_id = S_id}}.

handle_call(_Request, _From, State = #state{}) ->
  {reply, ok, State}.

handle_cast({send, From, To, Payload}, State = #state{}) ->
  Updated_messages_in_transit = State#state.messages_in_transit ++ [{From, To, Payload}],
%%  if whitelisted forward to message_sender and log from here?
  _Bool_whitelisted = check_if_whitelisted(From, To, Payload),
  {noreply, State#state{messages_in_transit = Updated_messages_in_transit}};
handle_cast({get_since_last}, State) ->
  erlang:display("get since last start"),
  gen_server:cast(State#state.message_interception_layer_id, {new_events, State#state.messages_in_transit}),
  {noreply, State#state{messages_in_transit = []}}.

handle_info(_Info, State = #state{}) ->
  {noreply, State}.

terminate(_Reason, _State = #state{}) ->
  ok.

code_change(_OldVsn, State = #state{}, _Extra) ->
  {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

check_if_whitelisted(_From, _To, _Payload) ->
%%  TODO: implemented whitelist check, currently none whitelisted; pay attention with transient crashes
  false.