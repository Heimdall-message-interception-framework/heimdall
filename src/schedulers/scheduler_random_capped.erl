%%%-------------------------------------------------------------------
%%% @author fms
%%% @copyright (C) 2021, <COMPANY>
%%% @doc
%%%
%%% @end
%%% Created : 06. Oct 2021 16:26
%%%-------------------------------------------------------------------
-module(scheduler_random_capped).
%% this version does only allow to execute the same type of commands as PCT and BFS
-author("fms").

-behaviour(scheduler).

-include("test_engine_types.hrl").

-export([get_kind_of_instruction/1, produce_sched_instruction/4, produce_timeout_instruction/2, start/1, init/1, update_state/2, choose_instruction/4, stop/1]).

%% SCHEDULER specific: state and parameters for configuration

-record(state, {}).

-define(ShareSUT_Instructions, 3).
-define(ShareSchedInstructions, 15).
-define(ShareTimeouts, 1).
-define(ShareNodeConnections, 0).

%%% BOILERPLATE for scheduler behaviour

start(InitialConfig) ->
  Config = maps:put(sched_name, ?MODULE, InitialConfig),
  scheduler:start(Config).

-spec choose_instruction(Scheduler :: pid(), SUTModule :: atom(), [#abstract_instruction{}], history()) -> #instruction{}.
choose_instruction(Scheduler, SUTModule, SchedInstructions, History) ->
  scheduler:choose_instruction(Scheduler, SUTModule, SchedInstructions, History).

-define(ListKindInstructionsShare, lists:flatten(
  [lists:duplicate(?ShareSUT_Instructions, sut_instruction),
    lists:duplicate(?ShareSchedInstructions, sched_instruction),
    lists:duplicate(?ShareTimeouts, timeout_instruction),
    lists:duplicate(?ShareNodeConnections, node_connection_instruction)])).

-spec get_kind_of_instruction(#state{}) -> kind_of_instruction().
get_kind_of_instruction(_State) ->
  lists:nth(rand:uniform(length(?ListKindInstructionsShare)), ?ListKindInstructionsShare).

%%% SCHEDULER callback implementations

init([_Config]) ->
  {ok, #state{}}.

stop(_State) ->
  ok.

-spec update_state(#state{}, list()) -> #state{}.
update_state(State, _) -> State.

-spec produce_sched_instruction(any(), list(), list(), #state{}) -> {#instruction{} | undefined, #state{}}.
produce_sched_instruction(_SchedInstructions, CommInTransit, _Timeouts, State) when CommInTransit == [] ->
  {undefined, State};
produce_sched_instruction(_SchedInstructions, CommInTransit, _Timeouts, State) when CommInTransit /= [] ->
  Command = helpers_scheduler:choose_from_list(CommInTransit),
  Args = helpers_scheduler:get_args_from_command_for_mil(Command),
  {#instruction{module = message_interception_layer, function = exec_msg_command, args = Args}, State}.

-spec produce_timeout_instruction(list(), #state{}) -> {#instruction{} | undefined, #state{}}.
produce_timeout_instruction(Timeouts, State) when Timeouts == [] ->
  {undefined, State};
produce_timeout_instruction(Timeouts, State) when Timeouts /= [] ->
  TimeoutToFire = helpers_scheduler:choose_from_list(Timeouts), % we also prioritise the ones in front
  {TimerRef, _, Proc, _, _, _, _} = TimeoutToFire, % this is too bad to pattern-match
  Args = [Proc, TimerRef],
  {#instruction{module = message_interception_layer, function = fire_timeout, args = Args}, State}.
