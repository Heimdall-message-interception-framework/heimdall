-module(bc_module_SUITE).
-include("test_engine_types.hrl").
-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0, test_engine/1, test_module/1, init_per_testcase/2]).

all() -> [
   test_module,
   test_engine
].

init_per_suite(Config) ->
  Config.

end_per_suite(_Config) ->
  _Config.

init_per_testcase(TestCase, Config) ->
  {ok, Scheduler} = scheduler_naive:start(),
  {ok, MIL} = message_interception_layer:start(Scheduler),
  application:set_env(sched_msg_interception_erlang, msg_int_layer, MIL),
  gen_server:cast(Scheduler, {register_message_interception_layer, MIL}),
  gen_server:cast(MIL, {start}),
  Config.

end_per_testcase(_, Config) ->
  Config.

test_module(_Config) ->
    % bc_module:bootstrap(),
    application:set_env(sched_msg_interception_erlang, bc_pids, [1,2,3,4,5]),
    AbstrInst = #abstract_instruction{module = causal_broadcast, function = broadcast},
    io:format("~p~n", [bc_module:generate_instruction(AbstrInst)]),
    io:format("~p~n", [bc_module:generate_instruction(AbstrInst)]),
    io:format("~p~n", [bc_module:generate_instruction(AbstrInst)]),
    io:format("~p~n", [bc_module:generate_instruction(AbstrInst)]).

test_engine(_Config) ->
  {ok, Engine} = gen_server:start_link(test_engine, [bc_module, self()], []),
  Runs = test_engine:explore(Engine, [#abstract_instruction{module=causal_broadcast, function=broadcast}], [], [], 5, 3),
  lists:foreach(fun({RunId, History}) -> io:format("Run ~p: ~p", [RunId,History]) end, Runs).



