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
-export([all/0, init_per_suite/1, end_per_suite/1, init_per_testcase/2, end_per_testcase/2, small_test/1,
  replay_naive_scheduler_same_payload_test/1, replay_naive_schedule_test/1, replay_client_req_test/1, replay_drop_req_test/1, replay_trans_crash_test/1]).

all() -> [
%%  replay_naive_schedule_test
%%  replay_naive_scheduler_same_payload_test
%%  replay_client_req_test
%%  replay_drop_req_test
  replay_trans_crash_test
%%  small_test
].

init_per_suite(Config) ->
  logger:set_primary_config(level, info),
  Config.

end_per_suite(_Config) ->
  _Config.

init_per_testcase(TestCase, Config) ->
  {FileReadable, ConfigReadable} = logging_configs:get_config_for_readable(TestCase),
  logger:add_handler(readable_handler, logger_std_h, ConfigReadable),
  {FileMachine, ConfigMachine} = logging_configs:get_config_for_machine(TestCase),
  logger:add_handler(machine_handler, logger_std_h, ConfigMachine),
  [{log_readable, FileReadable} | [{log_machine, FileMachine} | Config]].

end_per_testcase(_, Config) ->
  logger:remove_handler(readable_handler),
  logger:remove_handler(machine_handler),
  Config.

replay_naive_schedule_test(_Config) ->
  FileNameOriginal = "../../../../logs/schedules/2021-03-03-10:33:25_mil_naive_scheduler_test__machine.sched",
  {ok, ReplayScheduler} = replay_schedule:start(FileNameOriginal),
  {ok, MIL} = message_interception_layer:start(ReplayScheduler),
  gen_server:cast(ReplayScheduler, {register_message_interception_layer, MIL}),
  gen_server:cast(MIL, {start}),
  gen_server:cast(ReplayScheduler, {start}),
  timer:sleep(2500).

replay_naive_scheduler_same_payload_test(_Config) ->
  FileNameOriginal = "../../../../logs/schedules/2021-03-03-10:33:28_mil_naive_same_payload_scheduler_test__machine.sched",
  {ok, ReplayScheduler} = replay_schedule:start(FileNameOriginal),
  {ok, MIL} = message_interception_layer:start(ReplayScheduler),
  gen_server:cast(ReplayScheduler, {register_message_interception_layer, MIL}),
  gen_server:cast(MIL, {start}),
  gen_server:cast(ReplayScheduler, {start}),
  timer:sleep(2500).

replay_client_req_test(_Config) ->
  FileNameOriginal = "../../../../logs/schedules/2021-03-03-10:33:31_mil_client_req_test__machine.sched",
  {ok, ReplayScheduler} = replay_schedule:start(FileNameOriginal),
  {ok, MIL} = message_interception_layer:start(ReplayScheduler),
  gen_server:cast(ReplayScheduler, {register_message_interception_layer, MIL}),
  gen_server:cast(MIL, {start}),
  gen_server:cast(ReplayScheduler, {start}),
  timer:sleep(2500).

replay_drop_req_test(_Config) ->
  FileNameOriginal = "../../../../logs/schedules/2021-03-03-10:33:31_mil_drop_tests__machine.sched",
  {ok, ReplayScheduler} = replay_schedule:start(FileNameOriginal),
  {ok, MIL} = message_interception_layer:start(ReplayScheduler),
  gen_server:cast(ReplayScheduler, {register_message_interception_layer, MIL}),
  gen_server:cast(MIL, {start}),
  gen_server:cast(ReplayScheduler, {start}),
  timer:sleep(2500).

replay_trans_crash_test(_Config) ->
  FileNameOriginal = "../../../../logs/schedules/2021-03-03-13:40:00_mil_trans_crash_test__machine.sched",
  {ok, ReplayScheduler} = replay_schedule:start(FileNameOriginal),
  {ok, MIL} = message_interception_layer:start(ReplayScheduler),
  gen_server:cast(ReplayScheduler, {register_message_interception_layer, MIL}),
  gen_server:cast(MIL, {start}),
  gen_server:cast(ReplayScheduler, {start}),
  timer:sleep(8000).

small_test(_Config) ->
  FileNames = filelib:wildcard("./../../../../logs/schedules/*__machine.sched"),
  erlang:display(FileNames).
