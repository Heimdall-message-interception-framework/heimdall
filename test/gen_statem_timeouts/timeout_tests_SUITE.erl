%%%-------------------------------------------------------------------
%%% @author fms
%%% @copyright (C) 2021, <COMPANY>
%%% @doc
%%%
%%% @end
%%% Created : 23. Jul 2021 08:15
%%%-------------------------------------------------------------------
-module(timeout_tests_SUITE).
-author("fms").

-include_lib("common_test/include/ct.hrl").

%% API
-export([all/0, init_per_suite/1, end_per_suite/1, init_per_testcase/2, end_per_testcase/2]).
-export([test_event_to/1, test_event_to_keep_state/1, test_event_to_switch_state/1,
  test_state_to/1, test_state_to_keep_state/1, test_state_to_switch_state/1,
  test_general_to/1, test_general_to_keep_state/1, test_general_to_switch_state/1,
  test_state_to_cancel_to/1, test_state_to_set_inf/1, test_state_to_reset_time/1,
  test_general_to_cancel_to/1, test_general_to_set_inf/1, test_general_to_reset_time/1]).

all() -> [
  test_event_to,
  test_event_to_keep_state,
  test_event_to_switch_state,
  test_state_to,
  test_state_to_keep_state,
  test_state_to_switch_state,
  test_state_to_cancel_to,
  test_state_to_set_inf,
  test_state_to_reset_time,
  test_general_to,
  test_general_to_keep_state,
  test_general_to_switch_state,
  test_general_to_cancel_to,
  test_general_to_set_inf,
  test_general_to_reset_time
].

init_per_suite(Config) ->
  logger:set_primary_config(level, info),
  Config.

end_per_suite(_Config) ->
  _Config.

init_per_testcase(_TestCase, Config) ->
%%  start MIL and Scheduler
  {ok, Scheduler} = scheduler_naive:start(),
  {ok, MIL} = message_interception_layer:start(Scheduler),
  scheduler_naive:register_msg_int_layer(Scheduler, MIL),
  application:set_env(sched_msg_interception_erlang, msg_int_layer, MIL),
%%  start observer and state machine
  {ok, _Observer} = observer_timeouts:start(),
  {ok, _StatemPID} = statem_w_timeouts:start(),
%%  set logs
%%  {FileReadable, ConfigReadable} = logging_configs:get_config_for_readable(TestCase),
%%  logger:add_handler(readable_handler, logger_std_h, ConfigReadable),
%%  {FileMachine, ConfigMachine} = logging_configs:get_config_for_machine(TestCase),
%%  logger:add_handler(machine_handler, logger_std_h, ConfigMachine),
%%  [{log_readable, FileReadable} | [{log_machine, FileMachine} | Config]].
  Config.


end_per_testcase(_, Config) ->
%%  logger:remove_handler(readable_handler),
%%  logger:remove_handler(machine_handler),
  Config.

test_event_to(_Config) ->
  statem_w_timeouts:set_event_to(),
  timer:sleep(1000),
  ListEvents = observer_timeouts:get_list_events(),
  ExpectedEvents = [initial__set_event_to, event_TO__event_timed_out],
  assert_equal(ListEvents, ExpectedEvents).

test_event_to_keep_state(_Config) ->
  statem_w_timeouts:set_event_to(),
  statem_w_timeouts:keep_state(),
  timer:sleep(1000),
  ListEvents = observer_timeouts:get_list_events(),
  ExpectedEvents = [initial__set_event_to, any_state__keep_state],
  assert_equal(ListEvents, ExpectedEvents).

test_event_to_switch_state(_Config) ->
  statem_w_timeouts:set_event_to(),
  statem_w_timeouts:switch_state(),
  timer:sleep(1000),
  ListEvents = observer_timeouts:get_list_events(),
  ExpectedEvents = [initial__set_event_to, any_state__switch_state],
  assert_equal(ListEvents, ExpectedEvents).

test_state_to(_Config) ->
  statem_w_timeouts:set_state_to(),
  timer:sleep(1000),
  ListEvents = observer_timeouts:get_list_events(),
  ExpectedEvents = [initial__set_state_to, state_TO__state_timed_out],
  assert_equal(ListEvents, ExpectedEvents).

test_state_to_keep_state(_Config) ->
  statem_w_timeouts:set_state_to(),
  statem_w_timeouts:keep_state(),
  timer:sleep(1000),
  ListEvents = observer_timeouts:get_list_events(),
  ExpectedEvents = [initial__set_state_to, any_state__keep_state, state_TO__state_timed_out],
  assert_equal(ListEvents, ExpectedEvents).

test_state_to_switch_state(_Config) ->
  statem_w_timeouts:set_state_to(),
  statem_w_timeouts:switch_state(),
  timer:sleep(1000),
  ListEvents = observer_timeouts:get_list_events(),
  ExpectedEvents = [initial__set_state_to, any_state__switch_state],
  assert_equal(ListEvents, ExpectedEvents).

test_state_to_cancel_to(_Config) ->
  statem_w_timeouts:set_state_to(),
  statem_w_timeouts:cancel_state_to(),
  timer:sleep(1000),
  ListEvents = observer_timeouts:get_list_events(),
  ExpectedEvents = [initial__set_state_to, state_TO__cancelled],
  assert_equal(ListEvents, ExpectedEvents).

test_state_to_set_inf(_Config) ->
  statem_w_timeouts:set_state_to(),
  statem_w_timeouts:set_state_to(infinity),
  timer:sleep(1000),
  ListEvents = observer_timeouts:get_list_events(),
  ExpectedEvents = [initial__set_state_to, state_TO__set_to_infinity],
  assert_equal(ListEvents, ExpectedEvents).

test_state_to_reset_time(_Config) ->
  statem_w_timeouts:set_state_to(),
  statem_w_timeouts:set_state_to(200),
  timer:sleep(1000),
  ListEvents = observer_timeouts:get_list_events(),
  ExpectedEvents = [initial__set_state_to, state_TO__set_to_Time, state_TO__state_timed_out],
  assert_equal(ListEvents, ExpectedEvents).

test_general_to(_Config) ->
  statem_w_timeouts:set_general_to(),
  timer:sleep(1000),
  ListEvents = observer_timeouts:get_list_events(),
  ExpectedEvents = [initial__set_general_to, general_TO__general_timed_out],
  assert_equal(ListEvents, ExpectedEvents).

test_general_to_keep_state(_Config) ->
  statem_w_timeouts:set_general_to(),
  statem_w_timeouts:keep_state(),
  timer:sleep(1000),
  ListEvents = observer_timeouts:get_list_events(),
  ExpectedEvents = [initial__set_general_to, any_state__keep_state, general_TO__general_timed_out],
  assert_equal(ListEvents, ExpectedEvents).

test_general_to_switch_state(_Config) ->
  statem_w_timeouts:set_general_to(),
  statem_w_timeouts:switch_state(),
  timer:sleep(1000),
  ListEvents = observer_timeouts:get_list_events(),
  ExpectedEvents = [initial__set_general_to, any_state__switch_state, another_state__general_timed_out],
  assert_equal(ListEvents, ExpectedEvents).

test_general_to_cancel_to(_Config) ->
  statem_w_timeouts:set_general_to(),
  statem_w_timeouts:cancel_general_to(),
  timer:sleep(1000),
  ListEvents = observer_timeouts:get_list_events(),
  ExpectedEvents = [initial__set_general_to, general_TO__cancelled],
  assert_equal(ListEvents, ExpectedEvents).

test_general_to_set_inf(_Config) ->
  statem_w_timeouts:set_general_to(),
  statem_w_timeouts:set_general_to(infinity),
  timer:sleep(1000),
  ListEvents = observer_timeouts:get_list_events(),
  ExpectedEvents = [initial__set_general_to, general_TO__set_to_inf],
  assert_equal(ListEvents, ExpectedEvents).

test_general_to_reset_time(_Config) ->
  statem_w_timeouts:set_general_to(),
  statem_w_timeouts:set_general_to(200),
  timer:sleep(1000),
  ListEvents = observer_timeouts:get_list_events(),
  ExpectedEvents = [initial__set_general_to, general_TO__set_to_Time, general_TO__general_timed_out],
  assert_equal(ListEvents, ExpectedEvents).

%% Internal

assert_equal(First, Second) ->
  case First == Second of
    true -> ok;
    false -> ct:fail("not the same: ~p ~p", [First,Second])
  end.
