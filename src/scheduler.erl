%%%-------------------------------------------------------------------
%%% @author fms
%%% @copyright (C) 2021, <COMPANY>
%%% @doc
%%% @end
%%%-------------------------------------------------------------------
-module(scheduler).

-behaviour(gen_server).

-export([start/1]).
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

start(MIL) ->
  gen_server:start_link({local, ?SERVER}, ?MODULE, [MIL], []).

init([MIL]) ->
  {ok, #state{message_interception_layer_id = MIL}}.

handle_call(_Request, _From, State = #state{}) ->
  {reply, ok, State}.

handle_cast({new_events, ListNewMessages}, State = #state{}) ->
  UpdatedMessages = State#state.messages_in_transit ++ ListNewMessages,
  MsgUpdatedState = State#state{messages_in_transit = UpdatedMessages},
%%  compute next event to schedule
  {NextState, {KindEvent, ActualEvent}} = next_event_and_state(MsgUpdatedState),
  erlang:display("we got here"),
%% TODO:  depending on kind_event, take corresponding actions
  gen_server:cast(State#state.message_interception_layer_id, {KindEvent, ActualEvent}),
  {noreply, State#state{messages_in_transit = NextState}}.

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
  [{F, T, M} | Tail] = State#state.messages_in_transit,
  {State#state{messages_in_transit = Tail}, {send, {F, T, M}}}.

