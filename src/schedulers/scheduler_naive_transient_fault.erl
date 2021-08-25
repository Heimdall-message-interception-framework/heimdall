%%%-------------------------------------------------------------------
%%% @author fms
%%% @copyright (C) 2021, <COMPANY>
%%% @doc
%%% @end
%%%-------------------------------------------------------------------
-module(scheduler_naive_transient_fault).

-behaviour(gen_server).

-export([start/0, send_next_scheduling_instr/1, register_msg_int_layer/2]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2,
  code_change/3]).

-define(SERVER, ?MODULE).
-define(MIL, State#state.message_interception_layer_id).

-record(state, {
  message_interception_layer_id :: pid() | undefined,
  commands_in_transit = [] :: [{ID::any(), From::pid(), To::pid(), Module::atom(), Function::atom(), ListArgs::list(any())}]
}).

%%%===================================================================
%%% For External Use
%%%===================================================================

send_next_scheduling_instr(Scheduler) ->
  gen_server:cast(Scheduler, {send_next_sched}).

register_msg_int_layer(Scheduler, MIL) ->
  gen_server:cast(Scheduler, {register_message_interception_layer, MIL}).


%%%===================================================================
%%% Spawning and gen_server implementation
%%%===================================================================

start() ->
  gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

init([]) ->
  {ok, #state{}}.

handle_call(_Request, _From, State) ->
  {reply, ok, State}.

handle_cast({new_events, ListNewCommands}, State = #state{}) ->
  UpdatedCommands = State#state.commands_in_transit ++ ListNewCommands,
  send_next_scheduling_instr(self()), % react to new events with new scheduled events
  {noreply, State#state{commands_in_transit = UpdatedCommands}};
handle_cast({register_message_interception_layer, MIL}, State = #state{}) ->
  {noreply, State#state{message_interception_layer_id = MIL}};
handle_cast({send_next_sched}, State = #state{}) ->
  Result = next_event_and_state(State),
  case Result of
    {NextState, {ID, From, To, Mod, Func, Args}} ->
      message_interception_layer:exec_msg_command(?MIL, ID, From, To, Mod, Func, Args),
      {noreply, NextState};
    {NextState, {crash_trans, T}} ->
      message_interception_layer:transient_crash(?MIL, T),
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
%% this one simply returns the first element for 3 messages,
%% afterwards it crashes the process (transiently)
  case State#state.commands_in_transit of
    [] -> {State, {noop, {}}} ;
    [{ID,F,T,Mod,Func,Args} | Tail] ->
      case Args of
        [_, {message, 7}] ->
          FilteredCommands = lists:filter(fun({_,{_,To,_,_,_}}) -> To /= T end, Tail),
          {State#state{commands_in_transit = FilteredCommands}, {crash_trans, T}};
        _ -> {State#state{commands_in_transit = Tail}, {ID,F,T,Mod,Func,Args}}
      end
  end.



