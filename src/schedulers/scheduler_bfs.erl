%%%-------------------------------------------------------------------
%%% @author fms
%%% @copyright (C) 2021, <COMPANY>
%%% @doc
%%%
%%% @end
%%% Created : 06. Oct 2021 16:26
%%%-------------------------------------------------------------------
-module(scheduler_bfs).
-author("fms").

-behaviour(scheduler).

-include("test_engine_types.hrl").

-export([get_kind_of_instruction/1, produce_sched_instruction/4, produce_timeout_instruction/2, start/1, init/1, update_state/2, choose_instruction/4, stop/1]).

%% SCHEDULER specific: state and parameters for configuration

-record(state, {
  queue_commands = queue:new() :: queue:queue(),
  d_tuple :: [non_neg_integer()],
  delayed_commands = [] :: [any()], % store pairs of {index, command}
  num_seen_deviation_points = 0 :: integer()
}).

-define(ShareSUT_Instructions, 3).
-define(ShareSchedInstructions, 15).
-define(ShareTimeouts, 0).
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

-spec init(list()) -> {ok, #state{}}.
init([Config]) ->
  NumPossibleDevPoints = maps:get(num_possible_dev_points, Config, undefined),
  SizeDTuple = maps:get(size_d_tuple, Config, undefined),
  case (NumPossibleDevPoints == undefined) or (SizeDTuple == undefined) of
    true -> logger:warning("[~p] scheduler bfs not properly configured", [?MODULE]);
    false -> DTuple = helpers_scheduler:produce_d_tuple(SizeDTuple, NumPossibleDevPoints),
            {ok, #state{d_tuple = DTuple}}
  end.

stop(_State) ->
  ok.

-spec produce_sched_instruction(any(), any(), any(), #state{}) -> {#instruction{} | undefined, #state{}}.
produce_sched_instruction(_SchedInstructions, CommInTransit, _Timeouts, State) when CommInTransit == [] ->
  {undefined, State};
produce_sched_instruction(_SchedInstructions, _CommInTransit, Timeouts,
    #state{
      queue_commands = QueueCommands,
      delayed_commands = DelayedCommands,
      num_seen_deviation_points = NumDevPoints,
      d_tuple = DTuple
    } = State) ->
  case queue:out(QueueCommands) of
    {{value, NextCommand}, QueueCommands1} -> % go for next command from queue
      NumDevPoints1 = NumDevPoints + 1,
      State1 = State#state{queue_commands = QueueCommands1, num_seen_deviation_points = NumDevPoints1},
      case in_d_tuple(NumDevPoints1, DTuple) of
        {found, Index} ->
            DelayedCommands1 = [{Index, NextCommand} | DelayedCommands],
            State2 = State1#state{delayed_commands = DelayedCommands1},
            {undefined, State2};
        notfound ->
            {helpers_scheduler:get_instruction_from_command(NextCommand), State1}
      end;
    {empty, _} -> % go for delayed command or timeout
      case DelayedCommands of
        [] -> {produce_timeout_instruction(Timeouts, State), State};
        _ -> get_delayed_instruction(DelayedCommands, State)
      end
  end.

-spec produce_timeout_instruction(list(), #state{}) -> {#instruction{} | undefined, #state{}}.
produce_timeout_instruction(Timeouts, State) when Timeouts == [] ->
  {undefined, State};
produce_timeout_instruction(Timeouts, State) when Timeouts /= [] ->
  TimeoutToFire = helpers_scheduler:choose_from_list(Timeouts), % we also prioritise the ones in front
  {TimerRef, _, Proc, _, _, _, _} = TimeoutToFire, % this is too bad to pattern-match
  Args = [Proc, TimerRef],
  {#instruction{module = message_interception_layer, function = fire_timeout, args = Args}, State}.


-spec update_state(#state{}, [any()]) -> #state{}.
update_state(#state{queue_commands = QueueCommands, delayed_commands = DelayedCommands} = State,
    CommInTransit) ->
%% basically append all commands that were not seen before to queue
%%  assumes that we do our own bookkeeping correctly
  DelayedMappingFunc = fun({_Ind, Command}) -> Command end,
  IsCommandInQueueOrDelayed = fun(Cmd) ->
                                  queue:member(Cmd, QueueCommands) or
                                  lists:member(Cmd, lists:map(DelayedMappingFunc, DelayedCommands))
                              end,
  {_, CommandsNotSeen} = lists:partition(IsCommandInQueueOrDelayed, CommInTransit),
  QueueCommandsNotSeen = queue:from_list(lists:reverse(CommandsNotSeen)),
  State#state{queue_commands = queue:join(QueueCommands, QueueCommandsNotSeen)}.

-spec in_d_tuple(non_neg_integer(), list(non_neg_integer())) -> {found, non_neg_integer()} | notfound.
in_d_tuple(NumDevPoints, DTuple) ->
  HelperFunc = fun(X) -> X /= NumDevPoints end,
  SuffixDTuple = lists:dropwhile(HelperFunc, DTuple), % drops until it becomes NumDevPoints
  LenSuffix = length(SuffixDTuple),
  case LenSuffix == 0 of % predicate never got true so not in list
    true -> notfound;
    false -> {found, length(DTuple) - LenSuffix} % index from 0
  end.

%% also returns state
get_delayed_instruction(DelayedCommands, State) when DelayedCommands /= [] ->
%%  find next delayed command
  {Indices, _} = lists:unzip(DelayedCommands),
  SmallestIndex = lists:min(Indices),
  HelperFunc = fun({Index, Command}, Acc) -> case Index == SmallestIndex of
                                               false -> Acc;
                                               true -> Command
                                             end
               end,
  Command = lists:foldl(HelperFunc, undefined, DelayedCommands),
%%  update state
  DelayedCommands1 = lists:delete({SmallestIndex, Command}, DelayedCommands),
  State1 = State#state{delayed_commands = DelayedCommands1},
  {helpers_scheduler:get_instruction_from_command(Command), State1}.