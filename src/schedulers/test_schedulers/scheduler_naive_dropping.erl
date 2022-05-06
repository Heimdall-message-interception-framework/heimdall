%%%-------------------------------------------------------------------
%%% @author fms
%%% @copyright (C) 2021, <COMPANY>
%%% @doc
%%% @end
%%%-------------------------------------------------------------------
-module(scheduler_naive_dropping).

-behaviour(gen_server).

-export([start/0, send_next_scheduling_instr/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2,
  code_change/3]).

-define(SERVER, ?MODULE).

-record(state, {
  commands_in_transit = [] :: [{ID::any(), From::pid(), To::pid(), Module::atom(), Function::atom(), ListArgs::list(any())}]
}).

%%%===================================================================
%%% For External Use
%%%===================================================================

send_next_scheduling_instr(Scheduler) ->
  gen_server:cast(Scheduler, {send_next_sched}).


%%%===================================================================
%%% Spawning and gen_server implementation
%%%===================================================================

start() ->
  gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

init([]) ->
  {ok, #state{}}.

handle_call(_Request, _From, State = #state{}) ->
  {reply, ok, State}.

handle_cast({commands_it, ListCommands}, State = #state{}) ->
  send_next_scheduling_instr(self()), % react to new events with new scheduled events
  {noreply, State#state{commands_in_transit = ListCommands}};
handle_cast({send_next_sched}, State = #state{}) ->
  Result = next_event_and_state(State),
  case Result of
    {NextState, {ID, From, To, Mod, Func, Args}} ->
      message_interception_layer:exec_msg_command(ID, From, To, Mod, Func, Args),
      {noreply, NextState};
    {NextState, {drop, ID, From, To}} ->
      message_interception_layer:drop_msg_command(ID, From, To),
      {noreply, NextState};
    {NextState, {noop, {}}} ->
      {noreply, NextState}
  end.

handle_info(_Info, State) ->
  {noreply, State}.

terminate(_Reason, _State) ->
  ok.

code_change(_OldVsn, State, _Extra) ->
  {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

next_event_and_state(State) ->
%% this one simply returns the first element
  case State#state.commands_in_transit of
    [] -> {State, {noop, {}}} ;
    [{ID,F,T,Mod,Func,Args} | Tail] ->
      case Args of
        [_, {message, 5}] -> {State#state{commands_in_transit = Tail},
                              {drop, ID,F,T}};
        _ -> {State#state{commands_in_transit = Tail}, {ID,F,T,Mod,Func,Args}}
      end
  end.
