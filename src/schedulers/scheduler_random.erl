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

-include("test_engine_types.hrl").

-define(ShareSUT_Instructions, 3).
-define(ShareSchedInstructions, 15).
-define(ShareTimeouts, 1).
-define(ShareNodeConnections, 1).

-define(ShareMsgCmdExec, 20).
-define(ShareMsgCmdDup, 1).
-define(ShareMsgCmdDrop, 1).

-type kind_of_instruction() :: sut_instruction | sched_instruction | timeout_instruction | node_connection_instruction.
-type kind_of_sched_instruction() :: execute | duplicate | drop.

%% API
-export([choose_instruction/4, get_kind_of_instruction/0]).

%%-spec choose_instruction(any(), [#instruction{}], [#instruction{}], history()) -> #instruction{}.
%% added typing from dialyzer but where does {_, _} come from?
-spec choose_instruction(_,_,_,nonempty_improper_list(any(),{_,_})) -> #instruction{args::[any(),...]}.
choose_instruction(MIL, SUTInstructions, SchedInstructions, History) ->
  #state{commands_in_transit = CommInTransit,
          timeouts = Timeouts,
          nodes = Nodes,
          crashed = Crashed} = getLastStateOfHistory(History),
%%  we sample a number within the sum of all shares
  Result = get_next_instruction(MIL, SUTInstructions, SchedInstructions, CommInTransit, Timeouts, Nodes, Crashed),
  Result.


getLastStateOfHistory([_ | History]) ->
  getLastStateOfHistory(History);
getLastStateOfHistory({_, State}) ->
  State.


get_next_instruction(MIL, SUTInstructionModule, SchedInstructions, CommInTransit, Timeouts, Nodes, Crashed) ->
  KindInstruction = get_kind_of_instruction(),
  NextInstruction = case KindInstruction of
    sut_instruction -> produce_sut_instruction(SUTInstructionModule);
    sched_instruction -> produce_sched_instruction(MIL, SchedInstructions, CommInTransit);
    timeout_instruction -> produce_timeout_instruction(MIL, Timeouts);
    node_connection_instruction -> produce_node_connection_instruction(MIL, Nodes, Crashed)
  end,
%%  in case we produced a kind which was not possible, we simply retry
%%  TODO: improve this by checking first whether sched_instruction or timeout_instruction is possible
  case NextInstruction of
    undefined -> get_next_instruction(MIL, SUTInstructionModule, SchedInstructions, CommInTransit, Timeouts, Nodes, Crashed);
    ActualInstruction -> ActualInstruction
  end.

-spec produce_sut_instruction(any()) -> #instruction{}.
produce_sut_instruction(SUTInstructionModule) ->
  SUTInstructionModule:produce_instruction().

-spec produce_sched_instruction(any(), any(), any()) -> #instruction{} | undefined.
produce_sched_instruction(_MIL, _SchedInstructions, CommInTransit) when CommInTransit == [] ->
  undefined;
produce_sched_instruction(MIL, _SchedInstructions, CommInTransit) when CommInTransit /= [] ->
%%  first decide which action to take
  KindSchedInstruction = get_kind_of_sched_instruction(),
  case KindSchedInstruction of
    execute ->
      Command = choose_from_list(CommInTransit),
      Args = get_args_from_command_for_mil(Command),
      ArgsWithMIL = [MIL | Args],
      #instruction{module = message_interception_layer, function = exec_msg_command, args = ArgsWithMIL};
    duplicate ->  % always choose the first command
      [{Command, _} | _] = CommInTransit,
      Args = get_args_from_command_for_mil(Command),
      ArgsWithMIL = [MIL | Args],
      #instruction{module = message_interception_layer, function = duplicate_msg_command, args = ArgsWithMIL};
    drop -> % always choose the first command
      [{Command, _} | _] = CommInTransit,
      Args = get_args_from_command_for_mil(Command),
      ArgsWithMIL = [MIL | Args],
      #instruction{module = message_interception_layer, function = drop_msg_command, args = ArgsWithMIL}
  end.

-spec produce_timeout_instruction(any(), any()) -> #instruction{} | undefined.
produce_timeout_instruction(_MIL, Timeouts) when Timeouts == [] ->
  undefined;
produce_timeout_instruction(MIL, Timeouts) when Timeouts /= [] ->
  TimeoutToFire = choose_from_list(Timeouts), % we also prioritise the ones in front
  {Proc, TimerRef, _} = TimeoutToFire,
  Args = [MIL, Proc, TimerRef],
  #instruction{module = message_interception_layer, function = fire_timeout, args = Args}.

-spec produce_node_connection_instruction(any(), any(), any()) -> #instruction{} | undefined.
produce_node_connection_instruction(MIL, Nodes, Crashed) ->
  case Crashed of
    [] -> produce_crash_instruction(MIL, Nodes);
    _ -> case rand:uniform() * 2 < 1 of
           true -> produce_crash_instruction(MIL, Nodes);
           false -> produce_rejoin_instruction(MIL, Crashed)
         end
  end.

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

-spec get_kind_of_instruction() -> kind_of_instruction().
get_kind_of_instruction() ->
  SumShares = ?ShareSUT_Instructions + ?ShareSchedInstructions + ?ShareTimeouts + ?ShareNodeConnections,
  RandomNumber = rand:uniform() * SumShares,
  case RandomNumber < ?ShareSUT_Instructions of
    true -> sut_instruction;
    false -> case RandomNumber < ?ShareSUT_Instructions + ?ShareSchedInstructions of
               true -> sched_instruction;
               false ->
                 case RandomNumber < ?ShareSUT_Instructions + ?ShareSchedInstructions + ?ShareTimeouts  of
                   true -> timeout_instruction;
                   false -> node_connection_instruction
                 end
             end
  end.

-spec get_kind_of_sched_instruction() -> kind_of_sched_instruction().
get_kind_of_sched_instruction() ->
  SumShares = ?ShareMsgCmdExec + ?ShareMsgCmdDup + ?ShareMsgCmdDrop,
  RandomNumber = rand:uniform() * SumShares,
  case RandomNumber < ?ShareMsgCmdExec of
    true -> execute;
    false -> case RandomNumber < ?ShareMsgCmdExec + ?ShareMsgCmdDup of
               true -> duplicate;
               false -> drop
             end
  end.

choose_from_list(List) ->
  choose_from_list(List, 5).
choose_from_list(List, Trials) when Trials == 0 ->
%%  pick first; possible since the list cannot be empty
  [{Element, _} | _] = List,
  Element;
choose_from_list(List, Trials) when Trials > 0 ->
  HelperFunction = fun(X, Acc) ->
    case Acc of
      undefined -> RandomNumber = rand:uniform() * 4, % 75% chance to pick first command
                    case RandomNumber < 3 of
                      true -> X;
                      false -> undefined
                    end
    end
    end,
  MaybeElement = lists:foldl(HelperFunction, undefined, List),
  case MaybeElement of
    undefined -> choose_from_list(List, Trials-1);
    Element -> Element
  end.

get_args_from_command_for_mil(Command) ->
  {Id, From, To, _Module, _Function, _Args} = Command,
  [Id, From, To].