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
    % start ObserverManager and MIL
    {ok, OM} = gen_event:start({global,om}),
    {ok, MIL} = message_interception_layer:start(),
    Monitor = erlang:monitor(process, MIL),
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
    
    % check if our monitors report anything
    receive Msg ->
      io:format("Received: ~p~n", [Msg])
    after 0 ->
      ok
    end,

    % kill other processes
    gen_server:stop(MIL),
    gen_event:stop(OM).
    % process_flag(trap_exit, true).

test_engine(InitialConfig) ->
  {ok, Engine} = gen_server:start_link(test_engine, [bc_module, scheduler_random], []),
  MILInstructions = [],
  Conf = maps:from_list([{num_processes, 2}, {bc_type, best_effort_broadcast_paper}]
        ++ InitialConfig),
  Runs = test_engine:explore(Engine, bc_module, Conf,
                             MILInstructions, 100, 5),
  lists:foreach(fun({RunId, History}) -> io:format("Run ~p: ~p", [RunId,History]) end, Runs).



