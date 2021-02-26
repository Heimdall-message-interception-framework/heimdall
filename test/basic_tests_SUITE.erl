%%%-------------------------------------------------------------------
%%% @author fms
%%% @copyright (C) 2021, <COMPANY>
%%% @doc
%%% @end
%%%-------------------------------------------------------------------
-module(basic_tests_SUITE).
-include_lib("common_test/include/ct.hrl").
-include_lib("../src/sched_event.hrl").

-export([all/0,
  init_per_testcase/2,
  mil_naive_scheduler_test/1,
  mil_naive_same_payload_scheduler_test/1,
  mil_client_req_test/1,
  mil_drop_tests/1,
  mil_trans_crash_test/1,
  init_per_suite/1,
  end_per_suite/1]).

all() -> [mil_naive_scheduler_test,
          mil_naive_same_payload_scheduler_test,
          mil_client_req_test,
          mil_drop_tests,
          mil_trans_crash_test].

init_per_suite(Config) ->
  logger:set_primary_config(level, info),
%%  TODO: add filter if "what" is undefined
  LogConfigReadable = #{config => #{file => "./../../../../logs/schedules/sample_readable.log"},
                formatter => {logger_formatter, #{
                  template =>  [what, "\t",
                                {id, ["ID: ", id, "\t"], []},
                                {node, ["Node: ", node, "\t"], []},
                                {from, ["From: ", from, "\t"], []},
                                {to, [" To: ", to, "\t"], []},
                                {mesg, [" Msg: ", mesg, "\t"], []},
                                {old_mesg, [" Old Msg: ", old_mesg, "\t"], []},
                                {skipped, [" Skipped: ", skipped, "\t"], []},
                                  "\n"]
                }},
              level => debug},
  logger:add_handler(readable_handler, logger_std_h, LogConfigReadable),
  LogConfigMachine = #{config => #{file => "./../../../../logs/schedules/sample_machine.log"},
              formatter => {logger_formatter, #{
                template =>  ["{sched_event, ",
                  {what, ["\"", what, "\""], ["undefined"]}, ", ",
                  {id, [id], ["undefined"]}, ", ",
                  {node, ["\"", node, "\""], ["undefined"]}, ", ",
                  {from, ["\"", from, "\""], ["undefined"]}, ", ",
                  {to, ["\"", to, "\""], ["undefined"]}, ", ",
                  {mesg, ["\"", mesg, "\""], ["undefined"]}, ", ",
                  {old_mesg, ["\"", old_mesg, "\""], ["undefined"]}, ", ",
                  {skipped, [skipped], ["undefined"]},
                              "}.\n"]
              }},
    level => debug},
  logger:add_handler(machine_handler, logger_std_h, LogConfigMachine),
  Config.

end_per_suite(Config) ->
  Config.

init_per_testcase(_, Config) ->
  Config.

mil_naive_scheduler_test(_Config) ->
  {ok, Scheduler} = scheduler_naive:start(),
  {ok, MIL} = message_interception_layer:start(Scheduler, []),
  gen_server:cast(Scheduler, {register_message_interception_layer, MIL}),
  {ok, DummyReceiver1} = dummy_receiver:start_link(dr1),
  {ok, DummyReceiver2} = dummy_receiver:start_link(dr2),
  gen_server:cast(MIL, {register, {dr1, DummyReceiver1}}),
  gen_server:cast(MIL, {register, {dr2, DummyReceiver2}}),
  {ok, DummySender1} = dummy_sender:start(ds1, MIL),
  {ok, DummySender2} = dummy_sender:start(ds2, MIL),
  gen_server:cast(MIL, {register, {ds1, DummySender1}}),
  gen_server:cast(MIL, {register, {ds2, DummySender2}}),
  gen_server:cast(MIL, {start}),
%%  send the messages
  gen_server:cast(DummySender1, {send_N_messages_with_interval, {10, DummyReceiver1, 75}}),
  gen_server:cast(DummySender2, {send_N_messages_with_interval, {10, DummyReceiver2, 75}}),
  timer:sleep(2500),
  ReceivedMessages1 = gen_server:call(DummyReceiver1, {get_received_payloads}),
  ReceivedMessages2 = gen_server:call(DummyReceiver2, {get_received_payloads}),
  assert_equal(ReceivedMessages1, [10,9,8,7,6,5,4,3,2,1,0]),
  assert_equal(ReceivedMessages2, [10,9,8,7,6,5,4,3,2,1,0]).


mil_naive_same_payload_scheduler_test(_Config) ->
  {ok, Scheduler} = scheduler_naive_same_payload:start(1),
  {ok, MIL} = message_interception_layer:start(Scheduler, []),
  gen_server:cast(Scheduler, {register_message_interception_layer, MIL}),
  {ok, DummyReceiver1} = dummy_receiver:start_link(dr1),
  {ok, DummyReceiver2} = dummy_receiver:start_link(dr2),
  gen_server:cast(MIL, {register, {dr1, DummyReceiver1}}),
  gen_server:cast(MIL, {register, {dr2, DummyReceiver2}}),
  {ok, DummySender1} = dummy_sender:start(ds1, MIL),
  {ok, DummySender2} = dummy_sender:start(ds2, MIL),
  gen_server:cast(MIL, {register, {ds1, DummySender1}}),
  gen_server:cast(MIL, {register, {ds2, DummySender2}}),
  gen_server:cast(MIL, {start}),
%%  send the messages
  gen_server:cast(DummySender1, {send_N_messages_with_interval, {10, DummyReceiver1, 75}}),
  gen_server:cast(DummySender2, {send_N_messages_with_interval, {10, DummyReceiver2, 75}}),
  timer:sleep(2500),
  ReceivedMessages1 = gen_server:call(DummyReceiver1, {get_received_payloads}),
  ReceivedMessages2 = gen_server:call(DummyReceiver2, {get_received_payloads}),
  assert_equal(ReceivedMessages1, [1,1,1,1,1,1,1,1,1,1,1]),
  assert_equal(ReceivedMessages2, [1,1,1,1,1,1,1,1,1,1,1]).


mil_client_req_test(_Config) ->
  {ok, Scheduler} = scheduler_naive_same_payload:start(1),
  {ok, MIL} = message_interception_layer:start(Scheduler, [client1]),
  gen_server:cast(Scheduler, {register_message_interception_layer, MIL}),
  {ok, DummyReceiver1} = dummy_receiver:start_link(dr1),
  gen_server:cast(MIL, {register, {dr1, DummyReceiver1}}),
  gen_server:cast(MIL, {start}),
  gen_server:cast(MIL, {client_req, client1, dr1, "client_req"}),
  timer:sleep(100),
  ReceivedMessages1 = gen_server:call(DummyReceiver1, {get_received_payloads}),
  assert_equal(ReceivedMessages1, ["client_req"]).

mil_drop_tests(_Config) ->
  {ok, Scheduler} = scheduler_naive_dropping:start(),
  {ok, MIL} = message_interception_layer:start(Scheduler, []),
  gen_server:cast(Scheduler, {register_message_interception_layer, MIL}),
  {ok, DummyReceiver1} = dummy_receiver:start_link(dr1),
  gen_server:cast(MIL, {register, {dr1, DummyReceiver1}}),
  {ok, DummySender1} = dummy_sender:start(ds1, MIL),
  gen_server:cast(MIL, {register, {ds1, DummySender1}}),
  gen_server:cast(MIL, {start}),
%%  send the messages
  gen_server:cast(DummySender1, {send_N_messages_with_interval, {10, DummyReceiver1, 75}}),
  timer:sleep(2500),
  ReceivedMessages1 = gen_server:call(DummyReceiver1, {get_received_payloads}),
  assert_equal(ReceivedMessages1, [10,9,8,7,6,4,3,2,1,0]).

mil_trans_crash_test(_Config) ->
%%  TODO: add deterministic case where second queue is also erased
  {ok, Scheduler} = scheduler_naive_transient_fault:start(),
  {ok, MIL} = message_interception_layer:start(Scheduler, []),
  gen_server:cast(Scheduler, {register_message_interception_layer, MIL}),
  {ok, DummyReceiver1} = dummy_receiver:start_link(dr1),
  {ok, DummySender1} = dummy_sender:start(ds1, MIL),
  gen_server:cast(MIL, {register, {dr1, DummyReceiver1}}),
  gen_server:cast(MIL, {register, {ds1, DummySender1}}),
  gen_server:cast(MIL, {start}),
%%  send the messages
  gen_server:cast(DummySender1, {send_N_messages_with_interval, {10, DummyReceiver1, 75}}),
  timer:sleep(2500),
  ReceivedMessages1 = gen_server:call(DummyReceiver1, {get_received_payloads}),
  assert_equal(ReceivedMessages1, [10,9,8]).

assert_equal(First, Second) ->
  case First == Second of
    true -> ok;
    false -> ct:fail("not the same")
  end.

