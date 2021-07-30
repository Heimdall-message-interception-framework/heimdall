-module(best_effort_broadcast_tests_SUITE).

% -include_lib("common_test/include/ct.hrl").

-export([all/0, no_crash_test_simple/1, with_crash_test_simple/1, init_per_testcase/2, init_per_suite/1, end_per_suite/1,end_per_testcase/2]).

all() -> [
%    no_crash_test,
    no_crash_test_simple
%    with_crash_test_simple
].

init_per_suite(Config) ->
  logger:set_primary_config(level, info),
  Config.

end_per_suite(_Config) ->
  _Config.

init_per_testcase(TestCase, Config) ->
  {_, ConfigReadable} = logging_configs:get_config_for_readable(TestCase),
  logger:add_handler(readable_handler, logger_std_h, ConfigReadable),
  {_, ConfigMachine} = logging_configs:get_config_for_machine(TestCase),
  logger:add_handler(machine_handler, logger_std_h, ConfigMachine),

  % create message interception layer
  {ok, Scheduler} = scheduler_cmd_naive:start(),
  {ok, MIL} = message_interception_layer:start(Scheduler),
  application:set_env(sched_msg_interception_erlang, msg_int_layer, MIL),
  gen_server:cast(Scheduler, {register_message_interception_layer, MIL}),
  gen_server:cast(MIL, {start}),

  Config.

end_per_testcase(_, Config) ->
  logger:remove_handler(readable_handler),
  logger:remove_handler(machine_handler),
  Config.

% a simple chat server for testing the broadcast:
chat_loop_simplified(LL, Name, Received) ->
    % initialize broadcast process
    {ok, B} = best_effort_broadcast_paper:start_link(LL, Name, self()),
    receive
        {post, From, Msg} ->
            best_effort_broadcast_paper:broadcast(B, Msg),
            From ! {self(), ok},
            chat_loop_simplified(LL, Name, Received);
        {deliver, Msg} ->
            chat_loop_simplified(LL, Name, [Msg|Received]);
        {get_received, From} ->
            From ! {self(), Received},
            chat_loop_simplified(LL, Name, Received);
        {crash, _From} ->
            erlang:error(crashed);
        Message ->
            io:format("[chat_loop] received unknown message: ~p~n", [Message]),
            chat_loop_simplified(LL, Name, Received)
    end.

no_crash_test(_Config) ->
    % Create dummy link layer for testing:
    TestNodes = [nodeA, nodeB, nodeC],
    MIL = application:get_env(sched_msg_interception_erlang, msg_int_layer, undefined),
    NamesPids = lists:map(fun(Name) ->
        {ok, Pid} = link_layer_dummy_node:start(MIL, Name),
        {Name, Pid}
    [{nodeA, LL1}, {nodeB, LL2}, {nodeC, LL3}] = NamesPids,

    lists:map(fun({Name, Pid}) -> gen_server:cast(MIL, {register, {Name, Pid, link_layer_dummy_node}}) end, NamesPids),
    lists:map(fun({Name, _}) -> gen_server:call(MIL, {reg_bc_node, {Name}}) end, NamesPids),
    Chat2 = spawn_link(fun() -> chat_loop(MIL, LL2, bc2, []) end),
    Chat3 = spawn_link(fun() -> chat_loop(MIL, LL3, bc3, []) end),

    % post a message to chatserver 1
    Chat1 ! {post, self(), 'Hello everyone!'},
    receive {Chat1, ok} -> ok end,

    % finish exchanging messages
%%    link_layer_dummy:finish(LLD),
    timer:sleep(2500),

    % check that all chat-servers got the message:
    Chat1 ! {get_received, self()},
    Chat2 ! {get_received, self()},
    Chat3 ! {get_received, self()},
    receive {Chat1, Received1} -> ok end,
    receive {Chat2, Received2} -> ok end,
    receive {Chat3, Received3} -> ok end,
    erlang:display("Received1"),
    erlang:display(Received1),
    basic_tests_SUITE:assert_equal(['Hello everyone!'], Received1),
    basic_tests_SUITE:assert_equal(['Hello everyone!'], Received2),
    basic_tests_SUITE:assert_equal(['Hello everyone!'], Received3).

no_crash_test_simple(_Config) ->
    % Create link layer for testing:
    {ok, LL} = link_layer_simple:start(),

    % Create 3 chat servers:
    Chat1 = spawn_link(fun() -> chat_loop_simplified(LL, bc1, []) end),
    Chat2 = spawn_link(fun() -> chat_loop_simplified(LL, bc2, []) end),
    Chat3 = spawn_link(fun() -> chat_loop_simplified(LL, bc3, []) end),

    % post a message to chatserver 1
    Chat1 ! {post, self(), 'Hello everyone!'},
    receive {Chat1, ok} -> ok end,

    % finish exchanging messages
%%    link_layer_dummy:finish(LLD),
    timer:sleep(1000),

    % check that all chat-servers got the message:
    Chat1 ! {get_received, self()},
    Chat2 ! {get_received, self()},
    Chat3 ! {get_received, self()},
    receive {Chat1, Received1} -> ok end,
    receive {Chat2, Received2} -> ok end,
    receive {Chat3, Received3} -> ok end,
    basic_tests_SUITE:assert_equal(['Hello everyone!'], Received1),
    basic_tests_SUITE:assert_equal(['Hello everyone!'], Received2),
    basic_tests_SUITE:assert_equal(['Hello everyone!'], Received3).

with_crash_test_simple(_Config) ->
    % Create link layer for testing:
    {ok, LL} = link_layer_simple:start(),
    % Create dummy link layer for testing:
    {ok, LL} = link_layer_simple:start(),
    Chat1 = spawn_link(fun() -> chat_loop_simplified(LL, bc1, []) end),
    Chat2 = spawn_link(fun() -> chat_loop_simplified(LL, bc2, []) end),
    % crash chatserver 2 after 1 second
    timer:sleep(1000),
    process_flag(trap_exit, true),
    exit(Chat2, crashed),
    % Chat2 ! {crash, self()},
    % receive {Chat2, ok} -> ok end,

    % post a message to chatserver 1
    Chat1 ! {post, self(), 'Hello everyone!'},
    receive {Chat1, ok} -> ok end,

    % wait for messages to be delivered
    timer:sleep(1000),

    Chat1 ! {get_received, self()},
    Chat3 ! {get_received, self()},
    receive {Chat1, Received1} -> ok end,
    receive {Chat3, Received3} -> ok end,
    basic_tests_SUITE:assert_equal(['Hello everyone!'], Received1),
    basic_tests_SUITE:assert_equal(['Hello everyone!'], Received3).
