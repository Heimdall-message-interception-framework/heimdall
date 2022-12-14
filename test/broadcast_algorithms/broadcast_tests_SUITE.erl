-module(broadcast_tests_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0, groups/0, no_crash_test/1, with_crash_test/1, causal_ordering_test/1, init_per_group/2, end_per_group/2, init_per_testcase/2, init_per_suite/1, end_per_suite/1,end_per_testcase/2]).

all() -> [
    {group,be_tests},
    {group,rb_tests},
    {group,rco_tests}
].

groups() -> [
    {rco_tests,
        [no_crash_test, with_crash_test, causal_ordering_test]
    },
    {rb_tests,
        [no_crash_test, with_crash_test]
    },
    {be_tests,
        [no_crash_test, with_crash_test]
    }
].

init_per_group(rco_tests, Config) ->
    % register broadcast observer
    [{broadcast, causal_broadcast} | Config];
init_per_group(rb_tests, Config) ->
    % register broadcast observer
    [{broadcast, reliable_broadcast} | Config];
init_per_group(be_tests, Config) ->
    % register broadcast observer
    [{broadcast, best_effort_broadcast_paper} | Config].

end_per_group(_GroupName, _Config) ->
    _Config.

init_per_suite(Config) ->
  logger:set_primary_config(level, info),
  Config.

end_per_suite(_Config) ->
  _Config.

init_per_testcase(causal_ordering_test, Config) ->
  % create observer manager
  {ok, _} = gen_event:start({local,om}),
  TestCase = causal_ordering_test,

  {_, ConfigReadable} = logging_configs:get_config_for_readable(TestCase),
  logger:add_handler(readable_handler, logger_std_h, ConfigReadable),
  {_, ConfigMachine} = logging_configs:get_config_for_machine(TestCase),
  logger:add_handler(machine_handler, logger_std_h, ConfigMachine),

  % create message interception layer
  {ok, _MIL} = message_interception_layer:start(),
  {ok, Scheduler} = scheduler_naive:start(),
  {ok, CTH} = commands_transfer_helper:start_link(Scheduler),
  commands_transfer_helper:start(CTH),

  NewConfig = Config ++ [{listen_to, ["bc1_rco", "bc2_rco", "bc3_rco"]}],
  gen_event:add_handler(om, causal_delivery, [maps:from_list(NewConfig)]),

  Config;
init_per_testcase(TestCase, Config) ->
  % create observer manager
  {ok, _} = gen_event:start({local,om}),

  {_, ConfigReadable} = logging_configs:get_config_for_readable(TestCase),
  logger:add_handler(readable_handler, logger_std_h, ConfigReadable),
  {_, ConfigMachine} = logging_configs:get_config_for_machine(TestCase),
  logger:add_handler(machine_handler, logger_std_h, ConfigMachine),

  % create message interception layer
  {ok, MIL} = message_interception_layer:start(),
  {ok, Scheduler} = scheduler_naive:start(),
  {ok, CTH} = commands_transfer_helper:start_link(Scheduler),
  commands_transfer_helper:start(CTH),
  Config.

end_per_testcase(_, Config) ->
  gen_server:stop(commands_transfer_helper),
  gen_server:stop(scheduler_naive),
  gen_server:stop(message_interception_layer),
  gen_event:stop(om),
  logger:remove_handler(readable_handler),
  logger:remove_handler(machine_handler),
  Config.

% a simple chat server for testing the broadcast:
chat_loop_simplified(BCType, LL, BC, Name, Received) ->
    % start broadcast if it does not exist yet
    case BC of
        undefined -> {ok, UseBC} = BCType:start_link(LL, Name, self());
        _ -> UseBC = BC    
    end,
    receive
        {post, From, Msg} ->
            BCType:broadcast(UseBC, Msg),
            From ! {self(), ok},
            chat_loop_simplified(BCType, LL, UseBC, Name, Received);
        {deliver, Msg} ->
            io:format("[chat_loop ~p] received message: ~p~n. Received messages: ~p", [Name,Msg, [Msg|Received]]),
            chat_loop_simplified(BCType, LL, UseBC, Name, [Msg|Received]);
        {get_received, From} ->
            From ! {self(), Received},
            chat_loop_simplified(BCType, LL, UseBC, Name, Received);
        {crash, _From} ->
            erlang:error(crashed);
        Message ->
            io:format("[chat_loop] received unknown message: ~p~n", [Message]),
            chat_loop_simplified(BCType, LL, UseBC, Name, Received)
    end.

no_crash_test(Config) ->
    % Create link layer for testing:
    {ok, LL} = link_layer_simple:start(),

    B = ?config(broadcast, Config),
    Chat1 = spawn_link(fun() -> chat_loop_simplified(B, LL, undefined, "bc1", []) end),
    Chat2 = spawn_link(fun() -> chat_loop_simplified(B, LL, undefined, "bc2", []) end),
    Chat3 = spawn_link(fun() -> chat_loop_simplified(B, LL, undefined, "bc3", []) end),

    % post a message to chatserver 1
    Chat1 ! {post, self(), 'Hello everyone!'},
    receive {Chat1, ok} -> ok end,

    % finish exchanging messages
    timer:sleep(1000),

    % check that all chat-servers got the message:
    Chat1 ! {get_received, self()},
    Chat2 ! {get_received, self()},
    Chat3 ! {get_received, self()},
    receive {Chat1, Received1} -> ok end,
    receive {Chat2, Received2} -> ok end,
    receive {Chat3, Received3} -> ok end,
    basic_tests_SUITE:assert_equal(Received1, Received2),
    basic_tests_SUITE:assert_equal(Received2, Received3),
    basic_tests_SUITE:assert_equal(['Hello everyone!'], Received1),
    basic_tests_SUITE:assert_equal(['Hello everyone!'], Received2),
    basic_tests_SUITE:assert_equal(['Hello everyone!'], Received3).

with_crash_test(Config) ->
    % Create link layer for testing:
    {ok, LL} = link_layer_simple:start(),

    % Create 3 chat servers using best effort broadcast:
    B = ?config(broadcast, Config),
    Chat1 = spawn_link(fun() -> chat_loop_simplified(B, LL, undefined, "bc1", []) end),
    Chat2 = spawn_link(fun() -> chat_loop_simplified(B, LL, undefined, "bc2", []) end),
    Chat3 = spawn_link(fun() -> chat_loop_simplified(B, LL, undefined, "bc3", []) end),

    % crash chatserver 2 after 100ms
    timer:sleep(100),
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

causal_ordering_test(Config) ->
    io:format("handlers before: ~p~n" , [gen_event:which_handlers(om)]),
    % Create link layer for testing:
    {ok, LL} = link_layer_simple:start(),

    % Create 3 chat servers using broadcast set in config:
    B = ?config(broadcast, Config),
    Chat1 = spawn_link(fun() -> chat_loop_simplified(B, LL, undefined, "bc1", []) end),
    Chat2 = spawn_link(fun() -> chat_loop_simplified(B, LL, undefined, "bc2", []) end),
    Chat3 = spawn_link(fun() -> chat_loop_simplified(B, LL, undefined, "bc3", []) end),

    % post a message to chatserver 1
    Chat1 ! {post, self(), 'Hello everyone!'},
    Chat2 ! {post, self(), 'Hello from 2!'},
    timer:sleep(1000),
    Chat1 ! {post, self(), 'My name is Marvin!'},
    receive {Chat1, ok} -> ok end,
    receive {Chat1, ok} -> ok end,
    receive {Chat2, ok} -> ok end,

    % finish exchanging messages
    timer:sleep(1000),

    % check that all chat-servers got the message:
    Chat1 ! {get_received, self()},
    Chat2 ! {get_received, self()},
    Chat3 ! {get_received, self()},
    receive {Chat1, Received1} -> ok end,
    receive {Chat2, Received2} -> ok end,
    receive {Chat3, Received3} -> ok end,
    ValidOrderings = [
        ['My name is Marvin!', 'Hello from 2!', 'Hello everyone!'],
        ['My name is Marvin!', 'Hello everyone!', 'Hello from 2!']
    ],
    ?assert(lists:member(Received1, ValidOrderings)),
    ?assert(lists:member(Received2, ValidOrderings)),
    ?assert(lists:member(Received3, ValidOrderings)),
    io:format("handlers after: ~p~n" , [gen_event:which_handlers(om)]).
    % basic_tests_SUITE:assert_equal(Received1, Received2).
    % basic_tests_SUITE:assert_equal(Received2, Received3).
    % basic_tests_SUITE:assert_equal(['Hello everyone!'], Received1),
    % basic_tests_SUITE:assert_equal(['Hello everyone!'], Received2),
    % basic_tests_SUITE:assert_equal(['Hello everyone!'], Received3).