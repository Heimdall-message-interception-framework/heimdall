%%%-------------------------------------------------------------------
%%% @author fms
%%% @copyright (C) 2021, <COMPANY>
%%% @doc
%%%
%%% @end
%%% Created : 23. Jul 2021 08:15
%%%-------------------------------------------------------------------
-module(timeout_mi_tests_SUITE).
-author("fms").

-include_lib("common_test/include/ct.hrl").

-define(TIMEOUTINTERVAL, 1000).

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
  % create observer manager
  {ok, _} = gen_event:start({local,om}),
  Config.

end_per_suite(_Config) ->
  _Config.

init_per_testcase(TestCase, Config) ->
%%  start MIL and Scheduler
  {ok, MIL} = message_interception_layer:start(),
  {ok, Scheduler} = scheduler_naive:start(),
  {ok, CTH} = commands_transfer_helper:start_link(Scheduler),
%%  start observer and state machine
  {ok, _Observer} = observer_timeouts:start(),
  {ok, StatemPID} = statem_w_timeouts_mi:start(),
  message_interception_layer:register_with_name(statem_w_timeouts_mi, StatemPID, statem_w_timeouts_mi),
     % we use the module as name here in case it is used in calls or casts
  message_interception_layer:register_with_name(client, self(), test_client),
%%  start the CTH
  commands_transfer_helper:start(CTH),
%%  set logs
  {FileReadable, ConfigReadable} = logging_configs:get_config_for_readable(TestCase),
  logger:add_handler(readable_handler, logger_std_h, ConfigReadable),
  {FileMachine, ConfigMachine} = logging_configs:get_config_for_machine(TestCase),
  logger:add_handler(machine_handler, logger_std_h, ConfigMachine),
  [{log_readable, FileReadable} | [{log_machine, FileMachine} | Config]].
%%  Config.


end_per_testcase(_, Config) ->
  gen_server:stop(message_interception_layer),
  logger:remove_handler(readable_handler),
  logger:remove_handler(machine_handler),
  Config.

test_event_to(_Config) ->
  statem_w_timeouts_mi:set_event_to(),
  timer:sleep(?TIMEOUTINTERVAL),
  ListEvents = observer_timeouts:get_list_events(),
  ExpectedEvents = [initial__set_event_to, event_TO__event_timed_out],
  assert_equal(ListEvents, ExpectedEvents).

test_event_to_keep_state(_Config) ->
  statem_w_timeouts_mi:set_event_to(),
  timer:sleep(100),
  statem_w_timeouts_mi:keep_state(),
  timer:sleep(?TIMEOUTINTERVAL),
  ListEvents = observer_timeouts:get_list_events(),
  ExpectedEvents = [initial__set_event_to, any_state__keep_state],
  assert_equal(ListEvents, ExpectedEvents).

test_event_to_switch_state(_Config) ->
  statem_w_timeouts_mi:set_event_to(),
  timer:sleep(100),
  statem_w_timeouts_mi:switch_state(),
  timer:sleep(?TIMEOUTINTERVAL),
  ListEvents = observer_timeouts:get_list_events(),
  ExpectedEvents = [initial__set_event_to, any_state__switch_state],
  assert_equal(ListEvents, ExpectedEvents).

test_state_to(_Config) ->
  statem_w_timeouts_mi:set_state_to(),
  timer:sleep(?TIMEOUTINTERVAL),
  ListEvents = observer_timeouts:get_list_events(),
  ExpectedEvents = [initial__set_state_to, state_TO__state_timed_out],
  assert_equal(ListEvents, ExpectedEvents).

test_state_to_keep_state(_Config) ->
  statem_w_timeouts_mi:set_state_to(),
  timer:sleep(100),
  statem_w_timeouts_mi:keep_state(),
  timer:sleep(?TIMEOUTINTERVAL),
  ListEvents = observer_timeouts:get_list_events(),
  ExpectedEvents = [initial__set_state_to, any_state__keep_state, state_TO__state_timed_out],
  assert_equal(ListEvents, ExpectedEvents).

test_state_to_switch_state(_Config) ->
  statem_w_timeouts_mi:set_state_to(),
  timer:sleep(100),
  statem_w_timeouts_mi:switch_state(),
  timer:sleep(?TIMEOUTINTERVAL),
  ListEvents = observer_timeouts:get_list_events(),
  ExpectedEvents = [initial__set_state_to, any_state__switch_state],
  assert_equal(ListEvents, ExpectedEvents).

test_state_to_cancel_to(_Config) ->
  statem_w_timeouts_mi:set_state_to(),
  timer:sleep(100),
  statem_w_timeouts_mi:cancel_state_to(),
  timer:sleep(?TIMEOUTINTERVAL),
  ListEvents = observer_timeouts:get_list_events(),
  ExpectedEvents = [initial__set_state_to, state_TO__cancelled],
  assert_equal(ListEvents, ExpectedEvents).

test_state_to_set_inf(_Config) ->
  statem_w_timeouts_mi:set_state_to(),
  timer:sleep(100),
  statem_w_timeouts_mi:set_state_to(infinity),
  timer:sleep(?TIMEOUTINTERVAL),
  ListEvents = observer_timeouts:get_list_events(),
  ExpectedEvents = [initial__set_state_to, state_TO__set_to_infinity],
  assert_equal(ListEvents, ExpectedEvents).

test_state_to_reset_time(_Config) ->
  statem_w_timeouts_mi:set_state_to(),
  timer:sleep(100),
  statem_w_timeouts_mi:set_state_to(200),
  timer:sleep(?TIMEOUTINTERVAL),
  ListEvents = observer_timeouts:get_list_events(),
  ExpectedEvents = [initial__set_state_to, state_TO__set_to_Time, state_TO__state_timed_out],
  assert_equal(ListEvents, ExpectedEvents).

test_general_to(_Config) ->
  statem_w_timeouts_mi:set_general_to(),
  timer:sleep(?TIMEOUTINTERVAL),
  ListEvents = observer_timeouts:get_list_events(),
  ExpectedEvents = [initial__set_general_to, general_TO__general_timed_out],
  assert_equal(ListEvents, ExpectedEvents).

test_general_to_keep_state(_Config) ->
  statem_w_timeouts_mi:set_general_to(),
  timer:sleep(100),
  statem_w_timeouts_mi:keep_state(),
  timer:sleep(?TIMEOUTINTERVAL),
  ListEvents = observer_timeouts:get_list_events(),
  ExpectedEvents = [initial__set_general_to, any_state__keep_state, general_TO__general_timed_out],
  assert_equal(ListEvents, ExpectedEvents).

test_general_to_switch_state(_Config) ->
  statem_w_timeouts_mi:set_general_to(),
  timer:sleep(100),
  statem_w_timeouts_mi:switch_state(),
  timer:sleep(?TIMEOUTINTERVAL),
  ListEvents = observer_timeouts:get_list_events(),
  ExpectedEvents = [initial__set_general_to, any_state__switch_state, another_state__general_timed_out],
  assert_equal(ListEvents, ExpectedEvents).

test_general_to_cancel_to(_Config) ->
  statem_w_timeouts_mi:set_general_to(),
  timer:sleep(100),
  statem_w_timeouts_mi:cancel_general_to(),
  timer:sleep(?TIMEOUTINTERVAL),
  ListEvents = observer_timeouts:get_list_events(),
  ExpectedEvents = [initial__set_general_to, general_TO__cancelled],
  assert_equal(ListEvents, ExpectedEvents).

test_general_to_set_inf(_Config) ->
  statem_w_timeouts_mi:set_general_to(),
  timer:sleep(100),
  statem_w_timeouts_mi:set_general_to(infinity),
  timer:sleep(?TIMEOUTINTERVAL),
  ListEvents = observer_timeouts:get_list_events(),
  ExpectedEvents = [initial__set_general_to, general_TO__set_to_inf],
  assert_equal(ListEvents, ExpectedEvents).

test_general_to_reset_time(_Config) ->
  statem_w_timeouts_mi:set_general_to(),
  timer:sleep(100),
  statem_w_timeouts_mi:set_general_to(200),
  timer:sleep(?TIMEOUTINTERVAL),
  ListEvents = observer_timeouts:get_list_events(),
  ExpectedEvents = [initial__set_general_to, general_TO__set_to_Time, general_TO__general_timed_out],
  assert_equal(ListEvents, ExpectedEvents).

%% Internal

assert_equal(First, Second) ->
  case First == Second of
    true -> ok;
    false -> ct:fail("not the same: ~p ~p", [First,Second])
  end.
