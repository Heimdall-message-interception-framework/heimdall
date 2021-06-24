%%%-------------------------------------------------------------------
%%% @author fms
%%% @copyright (C) 2021, <COMPANY>
%%% @doc
%%% @end
%%%-------------------------------------------------------------------
-module(scheduler_cmd_naive).

-behaviour(gen_server).

-export([start/0, start_scheduler/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2,
  code_change/3]).

-define(SERVER, ?MODULE).
-define(INTERVAL, 50).

-record(state, {
  message_interception_layer_id :: pid() | undefined,
  commands_in_transit = [] :: [{ID::any(), From::pid(), To::pid(), Module::atom(), Function::atom(), ListArgs::list(any())}]
}).

start_scheduler(Scheduler) ->
  gen_server:cast(Scheduler, {start}).

%%%===================================================================
%%% Spawning and gen_server implementation
%%%===================================================================

start() ->
  gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

init([]) ->
  {ok, #state{}}.

handle_call(_Request, _From, State) ->
  {reply, ok, State}.

handle_cast({start}, State) ->
  erlang:send_after(?INTERVAL, self(), trigger_send_next),
  {noreply, State};
%%
handle_cast({new_events, ListNewCommands}, State = #state{}) ->
  erlang:display(["new events", "length", length(ListNewCommands),
                    "ListNewCommands", ListNewCommands,
                    "CommandsSoFar", State#state.commands_in_transit]),
  UpdatedCommands = State#state.commands_in_transit ++ ListNewCommands,
  CmdUpdatedState = State#state{commands_in_transit = UpdatedCommands},
  Result = next_event_and_state(CmdUpdatedState),
  case Result of
    {NextState, {ID, From, To, Mod, Func, Args}} ->
      erlang:display("sched_cmd_naive:41, reach here"),
      MIL = State#state.message_interception_layer_id,
      message_interception_layer:exec_msg_command(MIL, ID, From, To, Mod, Func, Args),
      {noreply, NextState};
    {NextState, {noop, {}}} ->
      {noreply, NextState}
  end;
handle_cast({register_message_interception_layer, MIL}, State = #state{}) ->
  {noreply, State#state{message_interception_layer_id = MIL}}.
%%
handle_info(trigger_send_next, State = #state{}) ->
  Result = next_event_and_state(State#state.commands_in_transit),
  restart_timer(),
  case Result of
    {NextState, {ID, From, To, Mod, Func, Args}} ->
      erlang:display("sched_cmd_naive:61, reach here"),
      MIL = State#state.message_interception_layer_id,
      message_interception_layer:exec_msg_command(MIL, ID, From, To, Mod, Func, Args),
      {noreply, NextState};
    {NextState, {noop, {}}} ->
      {noreply, NextState}
  end;
%%
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

restart_timer() ->
%%  TODO: give option for this or scheduler asks for new events themself for?
  erlang:send_after(?INTERVAL, self(), trigger_send_next).

