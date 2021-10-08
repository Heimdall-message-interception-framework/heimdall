%%%-------------------------------------------------------------------
%%% @author fms
%%% @copyright (C) 2021, <COMPANY>
%%% @doc
%%% @end
%%%-------------------------------------------------------------------
-module(scheduler_naive).

-behaviour(gen_server).

-export([start/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2,
  code_change/3]).

-define(SERVER, ?MODULE).
-define(INTERVAL, 50).
-define(TIMEOUTINTERVAL, 750).
-define(MIL, State#state.message_interception_layer_id).

-record(state, {
  message_interception_layer_id = undefined :: pid() | undefined,
  commands_in_transit = [] :: [{ID::any(), From::pid(), To::pid(), Module::atom(), Function::atom(), ListArgs::list(any())}],
  timerref_timeouts = undefined :: reference() | undefined
}).

%%%===================================================================
%%% For External Use
%%%===================================================================

send_next_scheduling_instr(Scheduler) ->
  gen_server:cast(Scheduler, {send_next_sched}).

%%%===================================================================
%%% Spawning and gen_server implementation
%%%===================================================================

start(MIL) ->
  gen_server:start_link({local, ?SERVER}, ?MODULE, [MIL], []).

init([MIL]) ->
  {ok, #state{message_interception_layer_id = MIL}}.

handle_call(_Request, _From, State) ->
  {reply, ok, State}.

handle_cast({start}, State) ->
  erlang:send_after(?INTERVAL, self(), trigger_send_next),
  {noreply, State};
%%
handle_cast({commands_it, ListCommands}, State = #state{}) ->
  send_next_scheduling_instr(self()), % react to new events with new scheduled events
  {noreply, State#state{commands_in_transit = ListCommands}};
%%
handle_cast({register_message_interception_layer, MIL}, State = #state{}) ->
  {noreply, State#state{message_interception_layer_id = MIL}};
%%
handle_cast({send_next_sched}, State = #state{}) ->
  Result = next_event_and_state(State),
  case Result of
    {NextState, {ID, From, To, Mod, Func, Args}} ->
      message_interception_layer:exec_msg_command(?MIL, ID, From, To, Mod, Func, Args),
      TimerRefTimeouts = restart_timeout_timer(State#state.timerref_timeouts),
      {noreply, NextState#state{timerref_timeouts = TimerRefTimeouts}};
    {NextState, {noop, {}}} ->
      {noreply, NextState}
  end.

handle_info(trigger_send_next, State) ->
  send_next_scheduling_instr(self()),
  restart_timer(),
  {noreply, State};
handle_info({timeouts_timeout, TimerRef}, State) ->
  case State#state.timerref_timeouts == TimerRef of
    false -> {noreply, State};
    true -> poll_and_schedule_timeouts(?MIL),
             {noreply, State}
  end;
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
      {State#state{commands_in_transit = Tail}, {ID,F,T,Mod,Func,Args}}
  end.

poll_and_schedule_timeouts(MIL) ->
%%  type of EnabledTimeouts: orddict ( procs => orddict ( timerref => value ) )
    EnabledTimeouts = message_interception_layer:get_timeouts(MIL),
%%    just pick the first one for now
    FunFilterEnabledTimeouts = fun(_Key, Value) -> orddict:size(Value) > 0 end,
    ProcsWithEnabledTimeouts = orddict:filter(FunFilterEnabledTimeouts, EnabledTimeouts),
    ListProcsWithEnabledTimeouts = orddict:to_list(ProcsWithEnabledTimeouts),
    case length(ListProcsWithEnabledTimeouts) of
      0 -> ok;
      _ -> {Proc, TimeoutsProcsOrddict} = lists:nth(1, ListProcsWithEnabledTimeouts),
        TimeoutsProcsList = orddict:to_list(TimeoutsProcsOrddict),
%%        because we filtered for non-empty we do not need to check again
        {TimerRef, _} = lists:nth(1, TimeoutsProcsList),
        message_interception_layer:fire_timeout(MIL, Proc, TimerRef)
    end.

restart_timer() ->
%%  TODO: give option for this or scheduler asks for new events themself for?
    erlang:send_after(?INTERVAL, self(), trigger_send_next).

restart_timeout_timer(_PrevTimerRef) ->
%%  case PrevTimerRef of
%%    undefined -> ok;
%%    _ -> erlang:cancel_timer(PrevTimerRef)
%%  end,
%%  TimerRefTimeouts = restart_timeout_timer(?TIMEOUTINTERVAL, self(), trigger_poll_timeouts),
    TimerRefTimeouts = make_ref(),
    erlang:send_after(?TIMEOUTINTERVAL, self(), {timeouts_timeout, TimerRefTimeouts}),
    TimerRefTimeouts.