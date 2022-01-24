%%%-------------------------------------------------------------------
%%% @author fms
%%% @copyright (C) 2021, <COMPANY>
%%% @doc
%%%
%%% @end
%%% Created : 25. Oct 2021 14:56
%%%-------------------------------------------------------------------
-module(scheduler_pct_w_timeouts).
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
-define(ShareTimeouts, 1).
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
  scheduler_pct:init([Config]).

stop(State) ->
  scheduler_pct:stop(State).

-spec produce_sched_instruction(any(), any(), any(), any(), #state{}) -> {#instruction{} | undefined, #state{}}.
produce_sched_instruction(MIL, SchedInstructions, CommInTransit, Timeouts, State) ->
  scheduler_pct:produce_sched_instruction(MIL, SchedInstructions, CommInTransit, Timeouts, State).

-spec produce_timeout_instruction(any(), any(), #state{}) -> {#instruction{} | undefined, #state{}}.
produce_timeout_instruction(MIL, Timeouts, State) ->
  scheduler_pct:produce_timeout_instruction(Timeouts, MIL, State).

-spec update_state(#state{}, [any()]) -> #state{}.
update_state(State, CommInTransit) ->
  scheduler_pct:update_state(State, CommInTransit).