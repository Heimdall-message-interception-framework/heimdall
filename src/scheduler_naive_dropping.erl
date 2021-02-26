%%%-------------------------------------------------------------------
%%% @author fms
%%% @copyright (C) 2021, <COMPANY>
%%% @doc
%%% @end
%%%-------------------------------------------------------------------
-module(scheduler_naive_dropping).

-behaviour(gen_server).

-export([start/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2,
  code_change/3]).

-define(SERVER, ?MODULE).

-record(state, {
  message_interception_layer_id :: pid(),
  messages_in_transit = [] :: [{ID::any(), From::pid(), To::pid(), Msg::any()}]
}).

%%%===================================================================
%%% Spawning and gen_server implementation
%%%===================================================================

start() ->
  gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

init([]) ->
  {ok, #state{}}.

handle_call(_Request, _From, State = #state{}) ->
  {reply, ok, State}.

handle_cast({new_events, ListNewMessages}, State = #state{}) ->
  UpdatedMessages = State#state.messages_in_transit ++ ListNewMessages,
  MsgUpdatedState = State#state{messages_in_transit = UpdatedMessages},
  {NextState, {KindEvent, ActualEvent}} = next_event_and_state(MsgUpdatedState),
  gen_server:cast(State#state.message_interception_layer_id, {KindEvent, ActualEvent}),
  {noreply, NextState};
handle_cast({register_message_interception_layer, MIL}, State = #state{}) ->
  {noreply, State#state{message_interception_layer_id = MIL}}.

handle_info(_Info, State = #state{}) ->
  {noreply, State}.

terminate(_Reason, _State = #state{}) ->
  ok.

code_change(_OldVsn, State = #state{}, _Extra) ->
  {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================


next_event_and_state(State) ->
%% this one simply returns the first element
  case length(State#state.messages_in_transit) == 0 of
    true ->  {State, {noop, {}}} ;
    false ->
      [{ID,F,T,M} | Tail] = State#state.messages_in_transit,
      case M == 5 of
        true -> {State#state{messages_in_transit = Tail}, {drop, {ID,F,T}}};
        false -> {State#state{messages_in_transit = Tail}, {send, {ID,F,T}}}
      end
  end.


