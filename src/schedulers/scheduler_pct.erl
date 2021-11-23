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
    chain_key_prios :: lists:list(integer() | atom()), % list from low to high priority
%%    chain_key_prios = maps:new() :: maps:maps(any()), % map from priority to chainkey
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
            {ok, #state{
              d_tuple = DTuple,
              online_chain_covering = OnlineChainCovering,
              next_prio = SizeDTuple,
              chain_key_prios = lists:duplicate(SizeDTuple, no_chain)
              }
            }
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

terminate(_Reason, _State = #state{online_chain_covering = OCC}) ->
  gen_server:stop(OCC),
  ok.

%% internal functions

-spec getLastStateOfHistory(history()) -> #prog_state{}.
getLastStateOfHistory([]) ->
  #prog_state{};
getLastStateOfHistory([{_Cmd, State} | _Tail]) ->
  State.

-spec get_next_instruction(pid(), atom(), [#abstract_instruction{}], _, _, _, _, #state{}) -> {#instruction{}, #state{}}.
get_next_instruction(_MIL, SUTModule, _SchedInstructions, CommInTransit, _Timeouts, _Nodes, _Crashed, State)
  when CommInTransit == [] ->
  {produce_sut_instruction(SUTModule), State};
get_next_instruction(MIL, SUTModule, SchedInstructions, CommInTransit, Timeouts, _Nodes, _Crashed, State)
  when CommInTransit /= [] ->
  KindInstruction = get_kind_of_instruction(),
  case KindInstruction of
    sut_instruction -> {produce_sut_instruction(SUTModule), State};
    sched_instruction -> produce_sched_instruction(MIL, SchedInstructions, CommInTransit, Timeouts, State)
  end.

-spec produce_sut_instruction(atom()) -> #instruction{}.
produce_sut_instruction(SUTInstructionModule) ->
  % choose random abstract instruction
  Instructions = SUTInstructionModule:get_instructions(),
  Instr = lists:nth(rand:uniform(length(Instructions)), Instructions),
  SUTInstructionModule:generate_instruction(Instr).

-spec produce_sched_instruction(any(), any(), any(), any(), #state{}) -> {#instruction{} | undefined, #state{}}.
produce_sched_instruction(_MIL, _SchedInstructions, CommInTransit, _Timeouts, State) when CommInTransit == [] ->
  {undefined, State};
produce_sched_instruction(MIL, _SchedInstructions, CommInTransit, _Timeouts,
    #state{
      online_chain_covering = OCC,
      chain_key_prios = ChainKeyPrios
    } = State) ->
  CmdID = get_next_from_chains(ChainKeyPrios, OCC, MIL),
  case  lists:filter(fun({ID, _, _, _, _, _}) -> ID == CmdID end, CommInTransit) of
    [{_, From, To, _, _, _}] ->
      ArgsWithMIL = [MIL, CmdID, From, To],
      Instruction = #instruction{module = message_interception_layer, function = exec_msg_command, args = ArgsWithMIL},
      {Instruction, State};
    SomethingElse -> erlang:display(["foudn this for command:", SomethingElse]),
      erlang:throw("did find this for ID in commands in transit: ~p")
  end.

-spec get_next_from_chains([integer()], any(), any()) -> {map(), #instruction{}}.
get_next_from_chains(ChainKeyPrios, OCC, MIL) ->
  Prios = lists:reverse(ChainKeyPrios),
  recursively_get_next_from_chains(Prios, OCC, MIL).

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
  chain_key_prios = ChainKeyPrios
  } = State,
    CommInTransit) ->
%%  1) get list of chain keys affected (with order and multiplicity) and annotate them with events-added-index
  ChainKeysAffected = online_chain_covering:add_events(OCC, CommInTransit), % list with one entry per added cmd
  ChainKeysAffectedUnique = sets:to_list(sets:from_list(ChainKeysAffected)),
  OldChainKeys = ChainKeyPrios,
  NewChainKeys = lists:subtract(ChainKeysAffectedUnique, OldChainKeys),
%%  1b) for each new chain_key, insert it
  ChainKeysPrios1 = lists:foldl(
    fun(ChainKey, ChainKeysPriosAcc) ->
      insert_chain_key_at_random_position(ChainKeysPriosAcc, ChainKey, DTuple) end,
    ChainKeyPrios,
      NewChainKeys),
  IndexList = lists:seq(EventsAdded, EventsAdded + length(ChainKeysAffected) - 1),
  IndexAndChainKeyAffected = lists:zip(IndexList, ChainKeysAffected),
%%  2) for each affected chain key, check whether event-added-index is in dtuple and (re-)insert accordingly
  ChainKeysPrios2 = lists:foldl(
    fun({Index, ChainKey}, ChainKeysPriosAcc) ->
      case in_d_tuple(Index, DTuple) of
        notfound ->
          ChainKeysPriosAcc;
        {found, IndexInDTuple1} -> % switch chainkey to the corresponding index
          ChainKeysPriosAccTemp1 = change_elem_in_list(ChainKey, ChainKeysPriosAcc, no_chain), % TODO: wrong index!?
          ChainKeysPriosAccTemp2 = update_nth_list(IndexInDTuple1, ChainKeysPriosAccTemp1, ChainKey),
          ChainKeysPriosAccTemp2
      end
    end,
    ChainKeysPrios1,
    IndexAndChainKeyAffected
  ),
  State#state{events_added = EventsAdded + length(ChainKeysAffected), chain_key_prios = ChainKeysPrios2}.

-spec in_d_tuple(non_neg_integer(), list(non_neg_integer())) -> {found, non_neg_integer()} | notfound.
in_d_tuple(NumDevPoints, DTuple) ->
  HelperFunc = fun(X) -> X /= NumDevPoints end,
  SuffixDTuple = lists:dropwhile(HelperFunc, DTuple), % drops until it becomes NumDevPoints
  LenSuffix = length(SuffixDTuple),
  case LenSuffix == 0 of % predicate never got true so not in list,
    true -> notfound;
    false -> {found, length(DTuple) - LenSuffix + 1} % index from 0 % TODO: fix sth here
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

insert_chain_key_at_random_position(ChainKeysPrios, ChainKey, DTuple) ->
    PriosAboveD = lists:nthtail(length(DTuple), ChainKeysPrios),
    % randomly choose at which to insert
    case PriosAboveD of
      [] -> % no priorities above d
        lists:reverse([ChainKey | lists:reverse(ChainKeysPrios)]);
      _ ->
        Position = rand:uniform(length(PriosAboveD) + 1) - 1,
        insert_elem_at_position_in_list(Position + length(DTuple), ChainKey, ChainKeysPrios)
    end.

recursively_get_next_from_chains(Prios, OCC, MIL) ->
%%  Prios have been reversed before calling
  case Prios of
    [] ->
      IDsInChains = online_chain_covering:get_all_ids_in_chains(OCC),
      erlang:display(["IDsInChains", IDsInChains]),
      erlang:throw("ran out of IDs in OCC even though there are commands in transit");
    [no_chain | RemPrios] ->
      recursively_get_next_from_chains(RemPrios, OCC, MIL);
    [ChainKeyMaxPrio | RemPrios] ->
      case online_chain_covering:get_first(OCC, ChainKeyMaxPrio) of
        empty -> % this chain was empty (for now)
          recursively_get_next_from_chains(RemPrios, OCC, MIL);
        {found, ID} -> ID % return ID and scheduler retrieves From and To
      end
  end.

insert_elem_at_position_in_list(Position, Elem, List) ->
  rec_insert_elem_at_position_in_list(Position, Elem, [], List).

rec_insert_elem_at_position_in_list(Position, Elem, RevPrefix, Suffix) ->
  case Position of
    0 -> lists:append(lists:reverse(RevPrefix), [Elem | Suffix]);
    Pos1 -> case Suffix of
      [] -> erlang:throw("list out of bounds");
      [Head | Tail] -> rec_insert_elem_at_position_in_list(Pos1 - 1, Elem, [Head | RevPrefix], Tail)
    end
  end.

update_nth_list(1, [_|Rest], New) -> [New|Rest];
update_nth_list(I, [E|Rest], New) ->
  case length([E|Rest]) < I of
    true -> erlang:display(["Position", I, "List", [E|Rest]]);
    false -> [E|update_nth_list(I-1, Rest, New)]
  end.

change_elem_in_list(_Old, [], _New) -> [];
change_elem_in_list(Old, [E|Rest], New) ->
  [case E == Old of true -> New; false -> E end |
    change_elem_in_list(Old, Rest, New)].
