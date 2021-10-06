%%%-------------------------------------------------------------------
%%% @author fms
%%% @copyright (C) 2021, <COMPANY>
%%% @doc
%%% @end
%%%-------------------------------------------------------------------
-module(basic_tests_SUITE).
-include_lib("common_test/include/ct.hrl").
-include_lib("sched_event.hrl").

-export([all/0,
  mil_naive_scheduler_test/1,
  mil_naive_same_payload_scheduler_test/1,
  mil_drop_tests/1,
  mil_trans_crash_test/1,
  init_per_suite/1, end_per_suite/1,
  init_per_testcase/2, end_per_testcase/2,
  assert_equal/2]).

all() -> [
          mil_naive_scheduler_test,
          mil_naive_same_payload_scheduler_test,
          mil_drop_tests,
          mil_trans_crash_test
%%          mil_duplicate_test % TODO: add one
         ].

init_per_suite(Config) ->
  logger:set_primary_config(level, info),
  % create observer manager
  {ok, _} = gen_event:start({global, om}),
  Config.

end_per_suite(_Config) ->
  _Config.

init_per_testcase(TestCase, Config) ->
  {_, ConfigReadable} = logging_configs:get_config_for_readable(TestCase),
  logger:add_handler(readable_handler, logger_std_h, ConfigReadable),
  {_, ConfigMachine} = logging_configs:get_config_for_machine(TestCase),
  logger:add_handler(machine_handler, logger_std_h, ConfigMachine),
  Config.

end_per_testcase(_, Config) ->
  logger:remove_handler(readable_handler),
  logger:remove_handler(machine_handler),
  Config.

mil_naive_scheduler_test(_Config) ->
%%  initiate Scheduler and MIL
  {ok, Scheduler} = scheduler_naive:start(),
  {ok, MIL} = message_interception_layer:start(Scheduler),
  scheduler_naive:register_msg_int_layer(Scheduler, MIL),
%%  start and register dummy senders and receivers
  {ok, DummySender1} = dummy_sender:start(ds1, MIL),
  {ok, DummySender2} = dummy_sender:start(ds2, MIL),
  {ok, DummyReceiver1} = dummy_receiver:start(dr1, MIL),
  {ok, DummyReceiver2} = dummy_receiver:start(dr2, MIL),
  message_interception_layer:register_with_name(MIL, ds1, DummySender1, dummy_sender),
  message_interception_layer:register_with_name(MIL, ds2, DummySender2, dummy_sender),
  message_interception_layer:register_with_name(MIL, dr1, DummyReceiver1, dummy_receiver),
  message_interception_layer:register_with_name(MIL, dr2, DummyReceiver2, dummy_receiver),
%%  start the MIL
  message_interception_layer:start_msg_int_layer(MIL),
%%  send the messages
  timer:sleep(100), % wait first a bit so that logging is in sync
  send_N_messages_with_interval(ds1, dr1, {10, 75}),
  send_N_messages_with_interval(ds2, dr2, {10, 75}),
  timer:sleep(2500),
%%  check the received messages
  ReceivedMessages1 = gen_server:call(DummyReceiver1, {get_received_payloads}),
  ReceivedMessages2 = gen_server:call(DummyReceiver2, {get_received_payloads}),
  assert_equal(ReceivedMessages1, [10,9,8,7,6,5,4,3,2,1,0]),
  assert_equal(ReceivedMessages2, [10,9,8,7,6,5,4,3,2,1,0]).


mil_naive_same_payload_scheduler_test(_Config) ->
%%  initiate Scheduler and MIL
  {ok, Scheduler} = scheduler_naive_same_payload:start(1),
  {ok, MIL} = message_interception_layer:start(Scheduler),
  scheduler_naive_same_payload:register_msg_int_layer(Scheduler, MIL),
%%  start and register dummy senders and receivers
  {ok, DummySender1} = dummy_sender:start(ds1, MIL),
  {ok, DummySender2} = dummy_sender:start(ds2, MIL),
  {ok, DummyReceiver1} = dummy_receiver:start(dr1, MIL),
  {ok, DummyReceiver2} = dummy_receiver:start(dr2, MIL),
  message_interception_layer:register_with_name(MIL, ds1, DummySender1, dummy_sender),
  message_interception_layer:register_with_name(MIL, ds2, DummySender2, dummy_sender),
  message_interception_layer:register_with_name(MIL, dr1, DummyReceiver1, dummy_receiver),
  message_interception_layer:register_with_name(MIL, dr2, DummyReceiver2, dummy_receiver),
%%  start the MIL
  message_interception_layer:start_msg_int_layer(MIL),
%%  send the messages
  timer:sleep(100), % wait first a bit so that logging is in sync
  send_N_messages_with_interval(ds1, dr1, {10, 75}),
  send_N_messages_with_interval(ds2, dr2, {10, 75}),
  timer:sleep(2500),
%%  check the received messages
  ReceivedMessages1 = gen_server:call(DummyReceiver1, {get_received_payloads}),
  ReceivedMessages2 = gen_server:call(DummyReceiver2, {get_received_payloads}),
  assert_equal(ReceivedMessages1, [1,1,1,1,1,1,1,1,1,1,1]),
  assert_equal(ReceivedMessages2, [1,1,1,1,1,1,1,1,1,1,1]).


mil_drop_tests(_Config) ->
  {ok, Scheduler} = scheduler_naive_dropping:start(),
  {ok, MIL} = message_interception_layer:start(Scheduler),
  scheduler_naive_dropping:register_msg_int_layer(Scheduler, MIL),
  {ok, DummyReceiver1} = dummy_receiver:start(dr1, MIL),
  {ok, DummySender1} = dummy_sender:start(ds1, MIL),
  message_interception_layer:register_with_name(MIL, ds1, DummySender1, dummy_sender),
  message_interception_layer:register_with_name(MIL, dr1, DummyReceiver1, dummy_receiver),
  message_interception_layer:start_msg_int_layer(MIL),
%%  send the messages
  send_N_messages_with_interval(ds1, dr1, {10, 75}),
  timer:sleep(2500),
%%  check the received messages
  ReceivedMessages1 = gen_server:call(DummyReceiver1, {get_received_payloads}),
  assert_equal(ReceivedMessages1, [10,9,8,7,6,4,3,2,1,0]).

mil_trans_crash_test(_Config) ->
%%  TODO: add deterministic case where second queue is also erased
  {ok, Scheduler} = scheduler_naive_transient_fault:start(),
  {ok, MIL} = message_interception_layer:start(Scheduler),
  scheduler_naive_transient_fault:register_msg_int_layer(Scheduler, MIL),
  {ok, DummyReceiver1} = dummy_receiver:start(dr1, MIL),
  {ok, DummySender1} = dummy_sender:start(ds1, MIL),
  message_interception_layer:register_with_name(MIL, ds1, DummySender1, dummy_sender),
  message_interception_layer:register_with_name(MIL, dr1, DummyReceiver1, dummy_receiver),
  message_interception_layer:start_msg_int_layer(MIL),
%%  send the messages
  send_N_messages_with_interval(ds1, dr1, {10, 75}),
  timer:sleep(2500),
  ReceivedMessages1 = gen_server:call(DummyReceiver1, {get_received_payloads}),
  assert_equal(ReceivedMessages1, [10,9,8]).

%%mil_duplicate_test(_Config) ->
%%  TODO: add deterministic case where second queue is also erased
%%  {ok, Scheduler} = scheduler_naive_duplicate_msg:start(5),
%%  {ok, MIL} = message_interception_layer:start(Scheduler),
%%  gen_server:cast(Scheduler, {register_message_interception_layer, MIL}),
%%  {ok, DummyReceiver1} = dummy_receiver:start(dr1, MIL),
%%  {ok, DummySender1} = dummy_sender:start(ds1, MIL),
%%  gen_server:cast(MIL, {register, {dr1, DummyReceiver1, dummy_receiver}}),
%%  gen_server:cast(MIL, {register, {ds1, DummySender1, dummy_sender}}),
%%  gen_server:cast(MIL, {start}),
%%%%  send the messages
%%  send_N_messages_with_interval(MIL, 10, ds1, dr1, 75),
%%  timer:sleep(2500),
%%  ReceivedMessages1 = gen_server:call(DummyReceiver1, {get_received_payloads}),
%%  assert_equal(ReceivedMessages1, [10,9,8,7,6,5,5,4,3,2,1,0]).
%%

%% HELPERS

%% internal for replaying
send_N_messages_with_interval(From, To, {N, Interval}) ->
  gen_server:cast(From, {send_N_messages_with_interval, To, {N, Interval}}).

assert_equal(First, Second) ->
  case First == Second of
    true -> ok;
    false -> ct:fail("not the same: ~p ~p", [First,Second])
  end.