%%%-------------------------------------------------------------------
%%% @author fms
%%% @copyright (C) 2021, <COMPANY>
%%% @doc
%%%
%%% @end
%%% Created : 06. Oct 2021 16:26
%%%-------------------------------------------------------------------
-module(scheduler_fifo_capped).
%% this version does only allow to execute the same type of commands as PCT and BFS
-author("fms").

-behaviour(gen_server).

-define(ShareSUT_Instructions, 3).
-define(ShareTimeouts, 1).

-include("test_engine_types.hrl").

-record(state, {}).

-type kind_of_instruction() :: sut_instruction | sched_instruction | timeout_instruction. % | node_connection_instruction.

-export([start_link/1, start/1, init/1, handle_call/3, handle_cast/2, terminate/2]).
-export([choose_instruction/5]).

%%% API
-spec start_link(_) -> {'ok', pid()}.
start_link(Config) ->
  gen_server:start_link({local, ?MODULE}, ?MODULE, [Config], []).

start(Config) ->
  gen_server:start({local, ?MODULE}, ?MODULE, [Config], []).

-spec choose_instruction(Scheduler :: pid(), MIL :: pid(), SUTModule :: atom(), [#abstract_instruction{}], history()) -> #instruction{}.
choose_instruction(Scheduler, MIL, SUTModule, SchedInstructions, History) ->
  %io:format("[~p] Choosing Instruction, History is: ~p~n", [?MODULE, History]),
  gen_server:call(Scheduler, {choose_instruction, MIL, SUTModule, SchedInstructions, History}).

%% gen_server callbacks

init([_Config]) ->
  {ok, #state{}}.

handle_call({choose_instruction, MIL, SUTModule, SchedInstructions, History}, _From, State = #state{}) ->
  #prog_state{commands_in_transit = CommInTransit,
    timeouts = Timeouts,
    nodes = Nodes,
    crashed = Crashed} = getLastStateOfHistory(History),
  Result = get_next_instruction(MIL, SUTModule, SchedInstructions, CommInTransit, Timeouts, Nodes, Crashed),
  {reply, Result, State};
handle_call(_Request, _From, State = #state{}) ->
  erlang:throw("unhandled call"),
  {reply, ok, State}.

handle_cast(_Request, State = #state{}) ->
  {noreply, State}.

terminate(_Reason, _State = #state{}) ->
  ok.

%% internal functions

-spec getLastStateOfHistory(history()) -> #prog_state{}.
getLastStateOfHistory([]) ->
  #prog_state{};
getLastStateOfHistory([{_Cmd, State} | _Tail]) ->
  State.

-spec get_next_instruction(pid(), atom(), [#abstract_instruction{}], _, _, _, _) -> #instruction{}.
get_next_instruction(MIL, SUTModule, SchedInstructions, CommInTransit, Timeouts, Nodes, Crashed) ->
  NextInstruction = case CommInTransit of
    [] -> KindInstruction = get_kind_of_instruction(),
          case KindInstruction of
            sut_instruction ->
              produce_sut_instruction(SUTModule);
            timeout_instruction ->
              produce_timeout_instruction(MIL, Timeouts)
          end;
    _ -> produce_sched_instruction(MIL, SchedInstructions, CommInTransit)
end,
%%  in case we produced a kind which was not possible, we simply retry
%%  TODO: improve this by checking first whether sched_instruction or timeout_instruction is possible
  case NextInstruction of
    undefined -> get_next_instruction(MIL, SUTModule, SchedInstructions, CommInTransit, Timeouts, Nodes, Crashed);
    ActualInstruction -> ActualInstruction
  end.

-spec produce_sut_instruction(atom()) -> #instruction{}.
produce_sut_instruction(SUTInstructionModule) ->
  % choose random abstract instruction
  Instructions = SUTInstructionModule:get_instructions(),
  Instr = lists:nth(rand:uniform(length(Instructions)), Instructions),
  SUTInstructionModule:generate_instruction(Instr).

-spec produce_sched_instruction(any(), any(), any()) -> #instruction{}.
produce_sched_instruction(MIL, _SchedInstructions, [Command | _]) ->
  Args = get_args_from_command_for_mil(Command),
  ArgsWithMIL = [MIL | Args],
  #instruction{module = message_interception_layer, function = exec_msg_command, args = ArgsWithMIL}.

-spec produce_timeout_instruction(any(), any()) -> #instruction{} | undefined.
produce_timeout_instruction(_MIL, Timeouts) when Timeouts == [] ->
  undefined;
produce_timeout_instruction(MIL, Timeouts) when Timeouts /= [] ->
  TimeoutToFire = choose_from_list(Timeouts), % we also prioritise the ones in front
  {TimerRef, _, Proc, _, _, _, _} = TimeoutToFire, % this is too bad to pattern-match
  Args = [MIL, Proc, TimerRef],
  #instruction{module = message_interception_layer, function = fire_timeout, args = Args}.

-spec get_kind_of_instruction() -> kind_of_instruction().
get_kind_of_instruction() ->
  SumShares = ?ShareSUT_Instructions + ?ShareTimeouts,
  RandomNumber = rand:uniform() * SumShares,
  case RandomNumber < ?ShareSUT_Instructions of
    true -> sut_instruction;
    false -> timeout_instruction
  end.

choose_from_list(List) ->
  choose_from_list(List, 5).
choose_from_list(List, Trials) when Trials == 0 ->
%%  pick first; possible since the list cannot be empty
  [Element | _] = List,
  Element;
choose_from_list(List, Trials) when Trials > 0 ->
  HelperFunction = fun(X, Acc) ->
    case Acc of
      undefined -> RandomNumber = rand:uniform() * 4, % 75% chance to pick first command
                    case RandomNumber < 3 of
                      true -> X;
                      false -> undefined
                    end;
      Cmd       -> Cmd
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