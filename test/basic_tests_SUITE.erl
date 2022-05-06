%%%-------------------------------------------------------------------
%%% @author fms
%%% @copyright (C) 2021, <COMPANY>
%%% @doc
%%% @end
%%%-------------------------------------------------------------------
-module(basic_tests_SUITE).
-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").
-include_lib("sched_event.hrl").

-define(ObserverManager, om).

-export([all/0,
  mil_naive_scheduler_test/1,
  mil_naive_same_payload_scheduler_test/1,
  mil_drop_tests/1,
  mil_trans_crash_test/1,
  init_per_suite/1, end_per_suite/1,
  init_per_testcase/2, end_per_testcase/2,
  assert_equal/2]).

all() -> [
%%          mil_naive_scheduler_test,
%%          mil_naive_same_payload_scheduler_test,
%%          mil_drop_tests,
          mil_trans_crash_test
%%          mil_duplicate_test % TODO: add one
         ].

init_per_suite(Config) ->
  logger:set_primary_config(level, info),
  % create observer manager
  {ok, _} = gen_event:start({local,om}),
  Config.

end_per_suite(_Config) ->
  _Config.

init_per_testcase(TestCase, Config) ->
  {_, ConfigReadable} = logging_configs:get_config_for_readable(TestCase),
  logger:add_handler(readable_handler, logger_std_h, ConfigReadable),
  {_, ConfigMachine} = logging_configs:get_config_for_machine(TestCase),
  logger:add_handler(machine_handler, logger_std_h, ConfigMachine),
%%  add observer
  gen_event:add_handler(?ObserverManager, mil_observer_template, [self(), true, true]), % propsat, armed
  Config.

end_per_testcase(_, Config) ->
  logger:remove_handler(readable_handler),
  logger:remove_handler(machine_handler),
%%  remove observer
  gen_event:delete_handler(?ObserverManager, mil_observer_template, []),
  Config.

mil_naive_scheduler_test(_Config) ->
%%  initiate Scheduler, MIL and ETH
  {ok, _MIL} = message_interception_layer:start_link(),
  {ok, Scheduler} = scheduler_naive:start(),
  {ok, CTH} = commands_transfer_helper:start_link(Scheduler),
%%  start and register dummy senders and receivers
  {ok, DummySender1} = dummy_sender:start(ds1),
  {ok, DummySender2} = dummy_sender:start(ds2),
  {ok, DummyReceiver1} = dummy_receiver:start(dr1),
  {ok, DummyReceiver2} = dummy_receiver:start(dr2),
  message_interception_layer:register_with_name(ds1, DummySender1, dummy_sender),
  message_interception_layer:register_with_name(ds2, DummySender2, dummy_sender),
  message_interception_layer:register_with_name(dr1, DummyReceiver1, dummy_receiver),
  message_interception_layer:register_with_name(dr2, DummyReceiver2, dummy_receiver),
%%  start the CTH
  commands_transfer_helper:start(CTH),
%%  send the messages
  timer:sleep(100), % wait first a bit so that logging is in sync
  send_N_messages_with_interval(ds1, dr1, {10, 75}),
  send_N_messages_with_interval(ds2, dr2, {10, 75}),
  timer:sleep(2500),
%%  check the received messages
  ReceivedMessages1 = gen_server:call(DummyReceiver1, {get_received_payloads}),
  ReceivedMessages2 = gen_server:call(DummyReceiver2, {get_received_payloads}),
  assert_equal(ReceivedMessages1, [10,9,8,7,6,5,4,3,2,1,0]),
  assert_equal(ReceivedMessages2, [10,9,8,7,6,5,4,3,2,1,0]),
%%  check the length of history
  HistoryOfEvents = gen_event:call(?ObserverManager, mil_observer_template, get_length_history),
  ?assert(HistoryOfEvents == 48).


mil_naive_same_payload_scheduler_test(_Config) ->
%%  initiate Scheduler, MIL and ETH
  {ok, _MIL} = message_interception_layer:start_link(),
  {ok, Scheduler} = scheduler_naive_same_payload:start(1),
  {ok, CTH} = commands_transfer_helper:start_link( Scheduler),
%%  start and register dummy senders and receivers
  {ok, DummySender1} = dummy_sender:start(ds1),
  {ok, DummySender2} = dummy_sender:start(ds2),
  {ok, DummyReceiver1} = dummy_receiver:start(dr1),
  {ok, DummyReceiver2} = dummy_receiver:start(dr2),
  message_interception_layer:register_with_name(ds1, DummySender1, dummy_sender),
  message_interception_layer:register_with_name(ds2, DummySender2, dummy_sender),
  message_interception_layer:register_with_name(dr1, DummyReceiver1, dummy_receiver),
  message_interception_layer:register_with_name(dr2, DummyReceiver2, dummy_receiver),
%%  start the CTH
  commands_transfer_helper:start(CTH),
%%  send the messages
  timer:sleep(100), % wait first a bit so that logging is in sync
  send_N_messages_with_interval(ds1, dr1, {10, 75}),
  send_N_messages_with_interval(ds2, dr2, {10, 75}),
  timer:sleep(2500),
%%  check the received messages
  ReceivedMessages1 = gen_server:call(DummyReceiver1, {get_received_payloads}),
  ReceivedMessages2 = gen_server:call(DummyReceiver2, {get_received_payloads}),
  assert_equal(ReceivedMessages1, [1,1,1,1,1,1,1,1,1,1,1]),
  assert_equal(ReceivedMessages2, [1,1,1,1,1,1,1,1,1,1,1]),
%%  check the length of history
  HistoryOfEvents = gen_event:call(?ObserverManager, mil_observer_template, get_length_history),
  ?assert(HistoryOfEvents == 48).


mil_drop_tests(_Config) ->
%%  initiate Scheduler, MIL and ETH
  {ok, _MIL} = message_interception_layer:start_link(),
  {ok, Scheduler} = scheduler_naive_dropping:start(),
  {ok, CTH} = commands_transfer_helper:start_link(Scheduler),
%%  start and register dummy senders and receivers
  {ok, DummyReceiver1} = dummy_receiver:start(dr1),
  {ok, DummySender1} = dummy_sender:start(ds1),
  message_interception_layer:register_with_name(ds1, DummySender1, dummy_sender),
  message_interception_layer:register_with_name(dr1, DummyReceiver1, dummy_receiver),
%%  start the CTH
  commands_transfer_helper:start(CTH),
%%  send the messages
  send_N_messages_with_interval(ds1, dr1, {10, 75}),
  timer:sleep(2500),
%%  check the received messages
  ReceivedMessages1 = gen_server:call(DummyReceiver1, {get_received_payloads}),
  assert_equal(ReceivedMessages1, [10,9,8,7,6,4,3,2,1,0]),
  %%  check the length of history
  HistoryOfEvents = gen_event:call(?ObserverManager, mil_observer_template, get_length_history),
  ?assert(HistoryOfEvents == 24).

mil_trans_crash_test(_Config) ->
%%  TODO: add deterministic case where second queue is also erased
%%  initiate Scheduler, MIL and ETH
  {ok, _MIL} = message_interception_layer:start_link(),
  {ok, Scheduler} = scheduler_naive_transient_fault:start(),
  {ok, CTH} = commands_transfer_helper:start_link(Scheduler),
%%  start and register dummy senders and receivers
  {ok, DummyReceiver1} = dummy_receiver:start(dr1),
  {ok, DummySender1} = dummy_sender:start(ds1),
  message_interception_layer:register_with_name(ds1, DummySender1, dummy_sender),
  message_interception_layer:register_with_name(dr1, DummyReceiver1, dummy_receiver),
%%  start the CTH
  commands_transfer_helper:start(CTH),
%%  send the messages
  send_N_messages_with_interval(ds1, dr1, {10, 75}),
  timer:sleep(2500),
  ReceivedMessages1 = gen_server:call(DummyReceiver1, {get_received_payloads}),
  assert_equal(ReceivedMessages1, [10,9,8]),
  %%  check the length of history
  HistoryOfEvents = gen_event:call(?ObserverManager, mil_observer_template, get_length_history),
  ?assert(HistoryOfEvents == 17).

%% HELPERS

%% internal for replaying
send_N_messages_with_interval(From, To, {N, Interval}) ->
  gen_server:cast(From, {send_N_messages_with_interval, To, {N, Interval}}).

assert_equal(First, Second) ->
  case First == Second of
    true -> ok;
    false -> ct:fail("not the same: ~p ~p", [First,Second])
  end.