%%%-------------------------------------------------------------------
%%% @author fms
%%% @copyright (C) 2021, <COMPANY>
%%% @doc
%%%
%%% @end
%%% Created : 02. Mar 2021 08:45
%%%-------------------------------------------------------------------
-module(replay_tests_SUITE).
-author("fms").

-include_lib("common_test/include/ct.hrl").
-include_lib("../src/sched_event.hrl").

%% API
-export([all/0, test_replay_naive_schedule/1, init_per_suite/1, end_per_suite/1, init_per_testcase/2, end_per_testcase/2]).

all() -> [
  test_replay_naive_schedule
].

init_per_suite(Config) ->
  logger:set_primary_config(level, info),
  Config.

end_per_suite(_Config) ->
  _Config.

init_per_testcase(TestCase, Config) ->
  logger:add_handler(readable_handler, logger_std_h, logging_configs:get_config_for_readable(TestCase)),
  logger:add_handler(machine_handler, logger_std_h, logging_configs:get_config_for_machine(TestCase)),
  Config.

end_per_testcase(_, Config) ->
  logger:remove_handler(readable_handler),
  logger:remove_handler(machine_handler),
  Config.

test_replay_naive_schedule(_Config) ->
  FileName = "./../../../../logs/schedules/2021-03-02-12:56:11_mil_naive_scheduler_test__machine.sched",
  {ok, BackUpScheduler} = scheduler_naive:start(),
  {ok, ReplayScheduler} = replay_schedule:start(FileName, BackUpScheduler),
  {ok, MIL} = message_interception_layer:start(ReplayScheduler),
  gen_server:cast(ReplayScheduler, {register_message_interception_layer, MIL}),
  gen_server:cast(MIL, {start}),
  gen_server:cast(ReplayScheduler, {start}),
  timer:sleep(2500).
