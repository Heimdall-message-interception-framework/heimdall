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
    chain_key_prios = maps:new() :: maps:maps(any()),
    next_prio :: integer()
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
            {ok, OnlineChainCovering} = online_chain_covering:start(Config),
            {ok, #state{d_tuple = DTuple, online_chain_covering = OnlineChainCovering, next_prio = SizeDTuple}}
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
%%    {NextInstruction, State2} =
      case (CommInTransit == []) or (KindInstruction == sut_instruction) of
        true -> {produce_sut_instruction(SUTModule), State};
        false -> produce_sched_instruction(MIL, SchedInstructions, CommInTransit, Timeouts, State)
      end.
%%    case NextInstruction of
%%      undefined -> get_next_instruction(MIL, SUTModule, SchedInstructions, CommInTransit, Timeouts, _Nodes, _Crashed, State2);
%%      _ -> {NextInstruction, State2}
%%    end.

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
      online_chain_covering = OCC,
      chain_key_prios = ChainKeyPrios
    } = State) ->
  {ChainKeyPrios1, Instruction} = get_next_from_chains(ChainKeyPrios, OCC, MIL),
  State1 = State#state{chain_key_prios = ChainKeyPrios1},
  {Instruction, State1}.

get_next_from_chains(ChainKeyPrios, OCC, MIL) ->
  Prios = maps:keys(ChainKeyPrios),
  MaxPrio = lists:max(Prios),
  ChainKeyMaxPrio = maps:get(MaxPrio, ChainKeyPrios),
  case online_chain_covering:get_first(OCC, ChainKeyMaxPrio) of
    {ID, From, To} ->
      ArgsWithMIL = [MIL | [ID | [From | To]]],
      Instruction = #instruction{module = message_interception_layer, function = exec_msg_command, args = ArgsWithMIL},
      {ChainKeyPrios, Instruction};
    empty -> % remove from chain_key_prios list and find again
      ChainKeyPrios1 = maps:remove(ChainKeyMaxPrio, ChainKeyPrios),
      get_next_from_chains(ChainKeyPrios1, OCC, MIL)
  end.

-spec get_kind_of_instruction() -> kind_of_instruction().
get_kind_of_instruction() ->
  SumShares = ?ShareSUT_Instructions + ?ShareSchedInstructions,
  RandomNumber = rand:uniform() * SumShares,
  case RandomNumber < ?ShareSUT_Instructions of
    true -> sut_instruction;
    false -> sched_instruction
  end.

-spec update_state(#state{}, [any()]) -> #state{}.
update_state(#state{
  events_added = EventsAdded,
  online_chain_covering = OCC,
  d_tuple = DTuple,
  chain_key_prios = ChainKeysPrios
  } = State,
    CommInTransit) ->
%%  add events and get list of added ids in order back
%%  TODO: do we need the 1st list?
  {ListIDsAdded, ChainKeysAffected} = online_chain_covering:add_events(OCC, CommInTransit),
  IndexList = lists:seq(1, length(ListIDsAdded)),
  IndexAndIDsAndChainKeys = lists:zip3(IndexList, ListIDsAdded, ChainKeysAffected),
  [{Index, _ID, ChainKey} | RemainingTriples] = IndexAndIDsAndChainKeys,
  {ChainKeysPrios1, TriplesToHandle} = case lists:member(ChainKey, ChainKeysPrios) of
      false -> {ChainKeysPrios, IndexAndIDsAndChainKeys};
      true -> % take care of this individually and check whether to decrease priority
             case in_d_tuple(Index, DTuple) of
               notfound -> {ChainKeysPrios, RemainingTriples};
               {found, IndexInDTuple} ->
                 ChainKeysPriosTemp1 = maps:remove(EventsAdded + Index, ChainKeysPrios), % remove ChainKey
                 ChainKeysPriosTemp2 = maps:update(IndexInDTuple, ChainKey, ChainKeysPriosTemp1),
                 {ChainKeysPriosTemp2, RemainingTriples}
             end
  end,
  ChainKeysPrios2 = lists:foldl(
    fun({Index, _ID, ChainKey}, ChainKeysPriosAcc) ->
      case in_d_tuple(Index, DTuple) of
        notfound ->
          Prios = maps:keys(ChainKeysPriosAcc),
          SortedPrios = lists:sort(Prios),
          {SortedPriosAboveD, _} = lists:partition(fun(Prio) -> Prio > length(DTuple) end, SortedPrios),
          % randomly choose after which to insert
          Position = rand:uniform(length(SortedPriosAboveD)),
          PrioBefore = lists:nth(Position, SortedPriosAboveD),
%%          TODO: nth does not support default values...
          PrioAfter = lists:nth(Position+1, SortedPriosAboveD, undefined),
          ChainKeysPriosAcc1 = case PrioAfter of
            undefined -> % chose last position so just add 20 indices later
              maps:update(PrioBefore+20, ChainKeysPriosAcc);
            _ActualPrio -> % CA on whether there is space between both prios
                               case PrioAfter - PrioBefore > 1 of
                                 false -> % no space so we double all prios above d to make space
                                   ChainKeysPriosTemp = lists:foldl(
                                     fun(OrigPrio, ChainKeysPriosAccTemp) ->
                                       ChainKey = maps:get(OrigPrio, ChainKeysPriosAccTemp),
                                       ChainKeysPriosTempp1 = maps:remove(OrigPrio, ChainKeysPriosAccTemp),
                                       maps:update(4*OrigPrio, ChainKey, ChainKeysPriosTempp1)
                                     end,
                                     ChainKeysPriosAcc,
                                     SortedPriosAboveD
                                   ),
                                   maps:update(4*PrioBefore + trunc((4*PrioAfter - 4*PrioBefore)/2), ChainKey, ChainKeysPriosTemp);
                                 true -> % can use some spot there, choose middle
                                   maps:update(PrioBefore + trunc((PrioAfter - PrioBefore)/2), ChainKey, ChainKeysPriosAcc)
                               end
          end,
          ChainKeysPriosAcc1;
        {found, IndexInDTuple1} ->
          ChainKeysPriosAccTemp1 = maps:remove(EventsAdded + Index, ChainKeysPrios), % remove ChainKey
          ChainKeysPriosAccTemp2 = maps:update(IndexInDTuple1, ChainKey, ChainKeysPriosAccTemp1),
          ChainKeysPriosAccTemp2
      end
    end,
    ChainKeysPrios1,
    TriplesToHandle
  ),
  State#state{events_added = EventsAdded + length(ListIDsAdded), chain_key_prios = ChainKeysPrios2}.


-spec in_d_tuple(non_neg_integer(), list(non_neg_integer())) -> {found, non_neg_integer()} | notfound.
in_d_tuple(NumDevPoints, DTuple) ->
  HelperFunc = fun(X) -> X /= NumDevPoints end,
  SuffixDTuple = lists:dropwhile(HelperFunc, DTuple), % drops until it becomes NumDevPoints
  LenSuffix = length(SuffixDTuple),
  case LenSuffix == 0 of % predicate never got true so not in list
    true -> notfound;
    false -> {found, length(DTuple) - LenSuffix} % index from 0
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