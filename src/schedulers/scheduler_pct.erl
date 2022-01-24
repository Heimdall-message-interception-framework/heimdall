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

-behaviour(scheduler).

-include("test_engine_types.hrl").

-export([get_kind_of_instruction/1, produce_sched_instruction/5, produce_timeout_instruction/3, start/1, init/1, update_state/2, choose_instruction/5, stop/1]).

%% SCHEDULER specific: state and parameters for configuration

-record(state, {
    online_chain_covering :: pid(),
    events_added = 0 :: integer(),
    d_tuple :: [non_neg_integer()],
    chain_key_prios :: [integer() | atom()], % list from low to high priority
%%    chain_key_prios = maps:new() :: maps:maps(any()), % map from priority to chainkey
    next_prio :: integer()
}).

-define(ShareSUT_Instructions, 3).
-define(ShareSchedInstructions, 15).
-define(ShareTimeouts, 0).
-define(ShareNodeConnections, 0).

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

init([Config]) ->
  NumPossibleDevPoints = maps:get(num_possible_dev_points, Config, undefined),
  SizeDTuple = maps:get(size_d_tuple, Config, undefined),
  case (NumPossibleDevPoints == undefined) or (SizeDTuple == undefined) of
    true -> logger:error("[~p] scheduler pct not properly configured", [?MODULE]);
    false -> DTuple = helpers_scheduler:produce_d_tuple(SizeDTuple, NumPossibleDevPoints),
            {ok, OnlineChainCovering} = online_chain_covering:start(Config),
            {ok, #state{
              d_tuple = DTuple,
              online_chain_covering = OnlineChainCovering,
              next_prio = SizeDTuple,
              chain_key_prios = lists:duplicate(SizeDTuple, no_chain)
              }
            }
  end.

stop(#state{online_chain_covering = OCC}) ->
  gen_server:stop(OCC).

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
    SomethingElse -> logger:warning(["found this for command:", SomethingElse]),
      logger:warning("did find this for ID in commands in transit: ~p")
  end.

-spec get_next_from_chains([integer()], any(), any()) -> {map(), #instruction{}}.
get_next_from_chains(ChainKeyPrios, OCC, MIL) ->
  Prios = lists:reverse(ChainKeyPrios),
  recursively_get_next_from_chains(Prios, OCC, MIL).

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
      case helpers_scheduler:in_d_tuple(Index, DTuple) of
        notfound ->
          ChainKeysPriosAcc;
        {found, IndexInDTuple1} -> % switch chainkey to the corresponding index
          ChainKeysPriosAccTemp1 = helpers_scheduler:change_elem_in_list(ChainKey, ChainKeysPriosAcc, no_chain), % TODO: wrong index!?
          ChainKeysPriosAccTemp2 = helpers_scheduler:update_nth_list(IndexInDTuple1, ChainKeysPriosAccTemp1, ChainKey),
          ChainKeysPriosAccTemp2
      end
    end,
    ChainKeysPrios1,
    IndexAndChainKeyAffected
  ),
  State#state{events_added = EventsAdded + length(ChainKeysAffected), chain_key_prios = ChainKeysPrios2}.


insert_chain_key_at_random_position(ChainKeysPrios, ChainKey, DTuple) ->
    PriosAboveD = lists:nthtail(length(DTuple), ChainKeysPrios),
    % randomly choose at which to insert
    case PriosAboveD of
      [] -> % no priorities above d
        lists:reverse([ChainKey | lists:reverse(ChainKeysPrios)]);
      _ ->
        Position = rand:uniform(length(PriosAboveD) + 1) - 1,
        helpers_scheduler:insert_elem_at_position_in_list(Position + length(DTuple), ChainKey, ChainKeysPrios)
    end.

recursively_get_next_from_chains(Prios, OCC, MIL) ->
%%  Prios have been reversed before calling
  case Prios of
%%    [] ->
%%      IDsInChains = online_chain_covering:get_all_ids_in_chains(OCC);
%%      erlang:display(["IDsInChains", IDsInChains]),
%%      erlang:throw("ran out of IDs in OCC even though there are commands in transit");
    [no_chain | RemPrios] ->
      recursively_get_next_from_chains(RemPrios, OCC, MIL);
    [ChainKeyMaxPrio | RemPrios] ->
      case online_chain_covering:get_first(OCC, ChainKeyMaxPrio) of
        empty -> % this chain was empty (for now)
          recursively_get_next_from_chains(RemPrios, OCC, MIL);
        {found, ID} -> ID % return ID and scheduler retrieves From and To
      end
  end.

%% will never be called since share for timeouts is 0 but needs to exist for callback implementation
produce_timeout_instruction(_MIL, _Timeouts, State) ->
  {undefined, State}.