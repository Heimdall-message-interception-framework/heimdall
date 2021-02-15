%%%-------------------------------------------------------------------
%%% @author fms
%%% @copyright (C) 2021, <COMPANY>
%%% @doc
%%% @end
%%%-------------------------------------------------------------------
-module(basic_tests).
-include_lib("eunit/include/eunit.hrl").


mil_naive_scheduler_tests() ->
  {ok, Scheduler} = naive_scheduler:start(),
  {ok, MIL, MessageCollector} = message_interception_layer:start(Scheduler, []),
  gen_server:cast(Scheduler, {register_message_interception_layer, MIL}),
  {ok, DummyReceiver1} = dummy_receiver:start_link(dr1),
  {ok, DummyReceiver2} = dummy_receiver:start_link(dr2),
  {ok, DummySender1} = dummy_sender:start(ds1, MessageCollector),
  {ok, DummySender2} = dummy_sender:start(ds2, MessageCollector),
  gen_server:cast(MIL, {start}),
%%  send the messages
  gen_server:cast(DummySender1, {send_N_messages_with_interval, {10, DummyReceiver1, 75}}),
  gen_server:cast(DummySender2, {send_N_messages_with_interval, {10, DummyReceiver2, 75}}),
  timer:sleep(2500),
  ReceivedMessages1 = gen_server:call(DummyReceiver1, {get_received_payloads}),
  ReceivedMessages2 = gen_server:call(DummyReceiver2, {get_received_payloads}),
  ?assertEqual(ReceivedMessages1, [10,9,8,7,6,5,4,3,2,1,0]),
  ?assertEqual(ReceivedMessages2, [10,9,8,7,6,5,4,3,2,1,0]).


mil_naive_same_payload_scheduler_tests() ->
  {ok, Scheduler} = naive_same_payload_scheduler:start(1),
  {ok, MIL, MessageCollector} = message_interception_layer:start(Scheduler, []),
  gen_server:cast(Scheduler, {register_message_interception_layer, MIL}),
  {ok, DummyReceiver1} = dummy_receiver:start_link(dr1),
  {ok, DummyReceiver2} = dummy_receiver:start_link(dr2),
  {ok, DummySender1} = dummy_sender:start(ds1, MessageCollector),
  {ok, DummySender2} = dummy_sender:start(ds2, MessageCollector),
  gen_server:cast(MIL, {start}),
%%  send the messages
  gen_server:cast(DummySender1, {send_N_messages_with_interval, {10, DummyReceiver1, 75}}),
  gen_server:cast(DummySender2, {send_N_messages_with_interval, {10, DummyReceiver2, 75}}),
  timer:sleep(2500),
  ReceivedMessages1 = gen_server:call(DummyReceiver1, {get_received_payloads}),
  ReceivedMessages2 = gen_server:call(DummyReceiver2, {get_received_payloads}),
  ?assertEqual(ReceivedMessages1, [1,1,1,1,1,1,1,1,1,1,1]),
  ?assertEqual(ReceivedMessages2, [1,1,1,1,1,1,1,1,1,1,1]).


mil_client_req_test() ->
  {ok, Scheduler} = naive_same_payload_scheduler:start(1),
  {ok, MIL, _} = message_interception_layer:start(Scheduler, [client1]),
  gen_server:cast(Scheduler, {register_message_interception_layer, MIL}),
  {ok, DummyReceiver1} = dummy_receiver:start_link(dr1),
  gen_server:cast(MIL, {start}),
  gen_server:cast(MIL, {client_req, client1, DummyReceiver1, "client_req"}),
  timer:sleep(100),
  ReceivedMessages1 = gen_server:call(DummyReceiver1, {get_received_payloads}),
  ?assertEqual(ReceivedMessages1, ["client_req"]).

