%%%-------------------------------------------------------------------
%%% @author fms
%%% @copyright (C) 2021, <COMPANY>
%%% @doc
%%% @end
%%%-------------------------------------------------------------------
-module(scheduler_naive_same_payload).

-behaviour(gen_server).

-export([start/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2,
  code_change/3]).

-define(SERVER, ?MODULE).

-record(state, {
  commands_in_transit = [] :: [{ID::any(), From::pid(), To::pid(), Module::atom(), Function::atom(), ListArgs::list(any())}],
  standard_payload :: any()
}).

%%%===================================================================
%%% For External Use
%%%===================================================================

send_next_scheduling_instr(Scheduler) ->
  gen_server:cast(Scheduler, {send_next_sched}).

%%%===================================================================
%%% Spawning and gen_server implementation
%%%===================================================================

start(StandardPayload) ->
  gen_server:start_link({local, ?SERVER}, ?MODULE, [StandardPayload], []).

init([StandardPayload]) ->
  {ok, #state{standard_payload = StandardPayload}}.

handle_call(_Request, _From, State = #state{}) ->
  {reply, ok, State}.

handle_cast({commands_it, ListNewCommands}, State = #state{}) ->
  send_next_scheduling_instr(self()), % react to new events with new scheduled events
  {noreply, State#state{commands_in_transit = ListNewCommands}};
handle_cast({send_next_sched}, State = #state{}) ->
  Result = next_event_and_state(State),
  case Result of
    {NextState, {snd_alter, ID, From, To, _Mod, _Func, NewArgs}} ->
      message_interception_layer:alter_msg_command(ID, From, To, NewArgs),
      {noreply, NextState};
    {NextState, {noop, {}}} ->
      {noreply, NextState}
  end.

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
  case State#state.commands_in_transit of
    [] -> {State, {noop, {}}} ;
    [{ID,F,T,Mod,Func,_Args} | Tail] ->
      {State#state{commands_in_transit = Tail},
        {snd_alter, ID,F,T,Mod,Func, [T, {message, State#state.standard_payload}]}}
  end.
