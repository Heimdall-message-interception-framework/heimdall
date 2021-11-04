%%%-------------------------------------------------------------------
%%% @author fms
%%% @copyright (C) 2021, <COMPANY>
%%% @doc
%%%
%%% @end
%%% Created : 25. Oct 2021 14:56
%%%-------------------------------------------------------------------
-module(scheduler_pct).
-author("fms").

-behaviour(gen_server).

-include("test_engine_types.hrl").

-define(ShareSUT_Instructions, 3).
-define(ShareSchedInstructions, 15).

-record(state, {
    online_chain_covering :: pid(),
    events_added = 0 :: integer(),
    d_tuple :: lists:list(non_neg_integer()),
    ids_with_d_tuple_index = [] :: lists:list(any()),
    chain_keys = [] :: lists:list(any()) % list of chain keys in priority order
}).

-type kind_of_instruction() :: sut_instruction | sched_instruction. % | timeout_instruction | node_connection_instruction.

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

init([Config]) ->
  NumPossibleDevPoints = maps:get(num_possible_dev_points, Config, undefined),
  SizeDTuple = maps:get(size_d_tuple, Config, undefined),
  case (NumPossibleDevPoints == undefined) or (SizeDTuple == undefined) of
    true -> erlang:throw("scheduler pct not properly configured");
    false -> DTuple = produce_d_tuple(SizeDTuple, NumPossibleDevPoints),
             OnlineChainCovering = online_chain_covering:start(Config),
            {ok, #state{d_tuple = DTuple, online_chain_covering = OnlineChainCovering}}
  end.

handle_call({choose_instruction, MIL, SUTModule, SchedInstructions, History}, _From, State = #state{}) ->
  #prog_state{commands_in_transit = CommInTransit,
    timeouts = Timeouts,
    nodes = Nodes,
    crashed = Crashed} = getLastStateOfHistory(History),
%%  first update state
  State1 = update_state(State, CommInTransit),
%%  then get next instruction
  {Instruction, State2} = get_next_instruction(MIL, SUTModule, SchedInstructions, CommInTransit, Timeouts, Nodes, Crashed, State1),
  {reply, Instruction, State2};
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

-spec get_next_instruction(pid(), atom(), [#abstract_instruction{}], _, _, _, _, #state{}) -> {#instruction{}, #state{}}.
get_next_instruction(MIL, SUTModule, SchedInstructions, CommInTransit, Timeouts, _Nodes, _Crashed, State) ->
  KindInstruction = get_kind_of_instruction(),
    {NextInstruction, State2} =
      case (CommInTransit == []) or (KindInstruction == sut_instruction) of
        true -> {produce_sut_instruction(SUTModule), State};
        false -> produce_sched_instruction(MIL, SchedInstructions, CommInTransit, Timeouts, State)
      end,
    case NextInstruction of
      undefined -> get_next_instruction(MIL, SUTModule, SchedInstructions, CommInTransit, Timeouts, _Nodes, _Crashed, State2);
      _ -> {NextInstruction, State2}
    end.

-spec produce_sut_instruction(atom()) -> #instruction{}.
produce_sut_instruction(SUTInstructionModule) ->
  % choose random abstract instruction
  Instructions = SUTInstructionModule:get_instructions(),
  Instr = lists:nth(rand:uniform(length(Instructions)), Instructions),
  SUTInstructionModule:generate_instruction(Instr).

-spec produce_sched_instruction(any(), any(), any(), any(), #state{}) -> {#instruction{} | undefined, #state{}}.
produce_sched_instruction(_MIL, _SchedInstructions, CommInTransit, _Timeouts, _State) when CommInTransit == [] ->
  undefined;
produce_sched_instruction(MIL, _SchedInstructions, _CommInTransit, Timeouts,
    #state{
      online_chain_covering = OCC
    } = State) ->
%%  TODO: need to use order of chain keys here
  case online_chain_covering:get_first_enabled(OCC, ChainKey) of
    {{ID, From, To}, EnabledIDs} -> ok;
    undefined -> ok; % TODO
  end,
%%  returns Maybe(Id, F, T) and which once become enabled if not none
  ok.


-spec get_kind_of_instruction() -> kind_of_instruction().
get_kind_of_instruction() ->
  SumShares = ?ShareSUT_Instructions + ?ShareSchedInstructions,
  RandomNumber = rand:uniform() * SumShares,
  case RandomNumber < ?ShareSUT_Instructions of
    true -> sut_instruction;
    false -> sched_instruction
  end.

get_args_from_command_for_mil(Command) ->
  {Id, From, To, _Module, _Function, _Args} = Command,
  [Id, From, To].

-spec update_state(#state{}, [any()]) -> #state{}.
update_state(#state{
  ids_with_d_tuple_index = IDsWithDTuple,
  events_added = EventsAdded,
  online_chain_covering = OCC
  } = State,
    CommInTransit) ->
%%  add events and get list of added ids in order back
  {ListIDsAdded, ChainKeysAdded} = online_chain_covering:add_events(OCC, CommInTransit),
%%  TODO: per id, check whether (index + EventsAdded) in d_tuple and store if so
%%  TODO: add ChainKeys to PriorityList
%%  TODO (return state)
  ok.


-spec in_d_tuple(non_neg_integer(), list(non_neg_integer())) -> {found, non_neg_integer()} | notfound.
in_d_tuple(NumDevPoints, DTuple) ->
  HelperFunc = fun(X) -> X /= NumDevPoints end,
  SuffixDTuple = lists:dropwhile(HelperFunc, DTuple), % drops until it becomes NumDevPoints
  LenSuffix = length(SuffixDTuple),
  case LenSuffix == 0 of % predicate never got true so not in list
    true -> notfound;
    false -> {found, length(DTuple) - LenSuffix} % index from 0
  end.

get_instruction_from_command(Command, MIL) ->
  Args = get_args_from_command_for_mil(Command),
  ArgsWithMIL = [MIL | Args],
  #instruction{module = message_interception_layer, function = exec_msg_command, args = ArgsWithMIL}.

get_timeout_instruction(Timeouts, MIL) when Timeouts /= [] ->
  TimeoutToFire = choose_from_list(Timeouts), % we also prioritise the ones in front
  {TimerRef, _, Proc, _, _, _, _} = TimeoutToFire, % this is too bad to pattern-match
  Args = [MIL, Proc, TimerRef],
  #instruction{module = message_interception_layer, function = fire_timeout, args = Args}.

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


produce_d_tuple(SizeDTuple, NumPossibleDevPoints) when SizeDTuple =< NumPossibleDevPoints ->
%%  idea: produce all possible integers and draw list from them until full
  AllNumbers = lists:seq(0, NumPossibleDevPoints-1),
  Steps = lists:seq(0, SizeDTuple-1),
  HelperFunc = fun(_, {DTuple0, AllNumbers0}) ->
                  NextElem = lists:nth(rand:uniform(length(AllNumbers0)), AllNumbers0),
                  AllNumbers1 = lists:delete(NextElem, AllNumbers0),
                  DTuple1 = [NextElem | DTuple0],
                  {DTuple1, AllNumbers1}
               end,
  {DTuple, _} = lists:foldl(HelperFunc, {[], AllNumbers}, Steps),
  DTuple.