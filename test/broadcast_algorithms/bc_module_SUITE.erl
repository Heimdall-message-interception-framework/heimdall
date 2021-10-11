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
  Config.

end_per_testcase(_, Config) ->
  Config.

test_module(InitialConfig) ->
    % bc_module:bootstrap(),
    {ok, MIL} = message_interception_layer:start(),
    application:set_env(sched_msg_interception_erlang, msg_int_layer, MIL),
    Conf = maps:from_list([{num_processes, 20}, {bc_type, best_effort_broadcast_paper}]
        ++ InitialConfig),
    {ok, BCMod} = bc_module:start_link(Conf),
    bc_module:bootstrap(),
    AbstrInst = #abstract_instruction{module = causal_broadcast, function = broadcast},
    io:format("~p~n", [bc_module:generate_instruction(AbstrInst)]),
    io:format("~p~n", [bc_module:generate_instruction(AbstrInst)]),
    io:format("~p~n", [bc_module:generate_instruction(AbstrInst)]),
    io:format("~p~n", [bc_module:generate_instruction(AbstrInst)]),
    
    process_flag(trap_exit, true),
    gen_server:stop(BCMod).
    % gen_server:stop({global,mil}).

test_engine(_Config) ->
  {ok, Engine} = gen_server:start_link(test_engine, [bc_module, scheduler_random], []),
  MILInstructions = [#abstract_instruction{}],
  Runs = test_engine:explore(Engine, bc_module, maps:from_list(_Config),
                             MILInstructions, 5, 3),
  lists:foreach(fun({RunId, History}) -> io:format("Run ~p: ~p", [RunId,History]) end, Runs).



