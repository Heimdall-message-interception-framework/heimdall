%%%-------------------------------------------------------------------
%%% @author fms
%%% @copyright (C) 2021, <COMPANY>
%%% @doc
%%%
%%% @end
%%% Created : 06. Oct 2021 16:26
%%%-------------------------------------------------------------------
-module(scheduler_random).
-author("fms").

-behaviour(scheduler).

-include("test_engine_types.hrl").

-export([get_kind_of_instruction/1, produce_sched_instruction/5, produce_timeout_instruction/3, start/1, init/1, update_state/2, choose_instruction/5, stop/1, produce_node_connection_instruction/4]).

%% SCHEDULER specific: state and parameters for configuration

-record(state, {}).

-define(ShareSUT_Instructions, 3).
-define(ShareSchedInstructions, 15).
-define(ShareTimeouts, 1).
-define(ShareNodeConnections, 1).

-type kind_of_sched_instruction() :: execute | duplicate | drop.
-define(ShareMsgCmdExec, 20).
-define(ShareMsgCmdDup, 1).
-define(ShareMsgCmdDrop, 1).

%%% BOILERPLATE for scheduler behaviour

start(InitialConfig) ->
  Config = maps:put(sched_name, ?MODULE, InitialConfig),
  scheduler:start(Config).

-spec choose_instruction(Scheduler :: pid(), MIL :: pid(), SUTModule :: atom(), [#abstract_instruction{}], history()) -> #instruction{}.
choose_instruction(Scheduler, MIL, SUTModule, SchedInstructions, History) ->
  scheduler:choose_instruction(Scheduler, MIL, SUTModule, SchedInstructions, History).

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

-spec produce_sched_instruction(any(), any(), any(), list(), #state{}) -> {#instruction{} | undefined, #state{}}.
produce_sched_instruction(_MIL, _SchedInstructions, CommInTransit, _Timeouts, State) when CommInTransit == [] ->
  {undefined, State};
produce_sched_instruction(MIL, _SchedInstructions, CommInTransit, _Timeouts, State) when CommInTransit /= [] ->
%%  first decide which action to take
  KindSchedInstruction = get_kind_of_sched_instruction(),
  Instruction = case KindSchedInstruction of
    execute ->
      Command = helpers_scheduler:choose_from_list(CommInTransit),
      Args = helpers_scheduler:get_args_from_command_for_mil(Command),
      ArgsWithMIL = [MIL | Args],
      #instruction{module = message_interception_layer, function = exec_msg_command, args = ArgsWithMIL};
    duplicate ->  % always choose the first command
      [Command | _] = CommInTransit,
      Args = helpers_scheduler:get_args_from_command_for_mil(Command),
      ArgsWithMIL = [MIL | Args],
      #instruction{module = message_interception_layer, function = duplicate_msg_command, args = ArgsWithMIL};
    drop -> % always choose the first command
      [Command  | _] = CommInTransit,
      Args = helpers_scheduler:get_args_from_command_for_mil(Command),
      ArgsWithMIL = [MIL | Args],
      #instruction{module = message_interception_layer, function = drop_msg_command, args = ArgsWithMIL}
  end,
  {Instruction, State}.

-spec produce_timeout_instruction(any(), any(), #state{}) -> {#instruction{} | undefined, #state{}}.
produce_timeout_instruction(_MIL, Timeouts, State) when Timeouts == [] ->
  {undefined, State};
produce_timeout_instruction(MIL, Timeouts, State) when Timeouts /= [] ->
  TimeoutToFire = helpers_scheduler:choose_from_list(Timeouts), % we also prioritise the ones in front
  {TimerRef, _, Proc, _, _, _, _} = TimeoutToFire, % this is too bad to pattern-match
  Args = [MIL, Proc, TimerRef],
  {#instruction{module = message_interception_layer, function = fire_timeout, args = Args}, State}.

-spec produce_node_connection_instruction(any(), any(), any(), #state{}) -> {#instruction{} | undefined, #state{}}.
produce_node_connection_instruction(MIL, Nodes, Crashed, State) ->
  Instruction = case Crashed of
    [] -> produce_crash_instruction(MIL, Nodes);
    _ -> case rand:uniform() * 2 < 1 of
           true -> produce_crash_instruction(MIL, Nodes);
           false -> produce_rejoin_instruction(MIL, Crashed)
         end
  end,
  {Instruction, State}.

produce_crash_instruction(MIL, Nodes) ->
%%  currently, we do not distinguish between transient and permanent crash
  NumberOfNodes = length(Nodes),
  NumberOfNodeToCrash = trunc(rand:uniform() * NumberOfNodes) + 1,
  NodeToCrash = lists:nth(NumberOfNodeToCrash, Nodes),
  Args = [MIL, NodeToCrash],
  #instruction{module = message_interception_layer, function = transient_crash, args = Args}.

produce_rejoin_instruction(MIL, Crashed) ->
  NumberOfCrashedNodes = length(Crashed),
  NumberOfNodeToRejoin = trunc(rand:uniform() * NumberOfCrashedNodes) + 1,
  NodeToRejoin = lists:nth(NumberOfNodeToRejoin, Crashed),
  Args = [MIL, NodeToRejoin],
  #instruction{module = message_interception_layer, function = rejoin, args = Args}.

-spec get_kind_of_sched_instruction() -> kind_of_sched_instruction().
get_kind_of_sched_instruction() ->
  List = lists:flatten(
    [lists:duplicate(?ShareMsgCmdExec, execute),
      lists:duplicate(?ShareMsgCmdDup, duplicate),
      lists:duplicate(?ShareMsgCmdDrop, drop)]
  ),
  lists:nth(rand:uniform(length(List)), List).

update_state(State, _CommInTransit) -> State.