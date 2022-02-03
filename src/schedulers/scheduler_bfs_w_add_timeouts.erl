%%%-------------------------------------------------------------------
%%% @author fms
%%% @copyright (C) 2021, <COMPANY>
%%% @doc
%%%
%%% @end
%%% Created : 06. Oct 2021 16:26
%%%-------------------------------------------------------------------
-module(scheduler_bfs_w_add_timeouts).
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
%% NOTE: this is the only difference to standard BFS
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

-spec init(list()) -> {ok, #state{}}.
init([Config]) ->
  scheduler_bfs:init([Config]).

stop(State) ->
  scheduler_bfs:stop(State).

-spec produce_sched_instruction(any(), list(), list(), #state{}) -> {#instruction{} | undefined, #state{}}.
produce_sched_instruction(SchedInstructions, CommInTransit, Timeouts, State) ->
  scheduler_bfs:produce_sched_instruction(SchedInstructions, CommInTransit, Timeouts, State).

-spec produce_timeout_instruction(list(), #state{}) -> {#instruction{} | undefined, #state{}}.
produce_timeout_instruction(Timeouts, State) ->
  scheduler_bfs:produce_timeout_instruction(Timeouts, State).

update_state(State, CommInTransit) ->
  scheduler_bfs:update_state(State, CommInTransit).
