-module(bc_module_SUITE).
-include("test_engine_types.hrl").
-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0, test_engine/1, test_module/1, init_per_testcase/2, init_per_suite/1, end_per_suite/1, test_scheduler_bfs/1, test_scheduler_pct/1]).

all() -> [
   test_module,
   test_engine,
   test_scheduler_bfs,
   test_scheduler_pct
].

init_per_suite(Config) ->
  logger:set_primary_config(level, debug),
  LogConf = #{config => #{file => "./MIL_log.log"}, level => debug},
  logger:add_handler(myhandler, logger_std_h, LogConf),
  Config.

end_per_suite(_Config) ->
  _Config.

init_per_testcase(TestCase, Config) ->
  Config ++ [{html_output, true}, {test_name, TestCase}].

end_per_testcase(_, Config) ->
  Config.

test_module(InitialConfig) ->
    % bc_module:bootstrap(),
    % start ObserverManager and MIL
    {ok, OM} = gen_event:start({local,om}),
    {ok, MIL} = message_interception_layer:start(),
    erlang:monitor(process, MIL),
    Conf = maps:from_list([{num_processes, 20}, {bc_type, best_effort_broadcast_paper}]
        ++ InitialConfig),
    {ok, BCMod} = bc_module:start_link(Conf),
    bc_module:bootstrap_wo_scheduler(),
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
  % enable html output
  {ok, Engine} = gen_server:start_link(test_engine, [bc_module, scheduler_random], []),
  MILInstructions = [],
  Conf = maps:from_list([
    {observers, [causal_delivery]},
    {num_processes, 2},
    {bc_type, causal_broadcast}
  ]
        ++ InitialConfig),
  ListenTo = lists:map(fun(Id) -> "bc" ++ integer_to_list(Id) ++ "_be" end, lists:seq(0, maps:get(num_processes, Conf)-1)),
  Conf2 = maps:put(listen_to, ListenTo, Conf),
  Timeout = infinity,
  Runs = test_engine:explore(Engine, bc_module, Conf2,
                             MILInstructions, 2, 10, Timeout),
  % stop html module -> blocks till all writes are done
  lists:foreach(fun({RunId, History}) -> io:format("Run ~p: ~p", [RunId,History]) end, Runs).



test_scheduler_bfs(InitialConfig) ->
  {ok, Engine} = gen_server:start_link(test_engine, [bc_module, scheduler_bfs], []),
  MILInstructions = [],
  Conf = maps:from_list([
    {observers, [causal_delivery]},
    {num_processes, 2},
    {bc_type, causal_broadcast},
    {num_possible_dev_points, 50},
    {size_d_tuple, 5}
  ]
  ++ InitialConfig),
  ListenTo = lists:map(fun(Id) -> "bc" ++ integer_to_list(Id) ++ "_be" end, lists:seq(0, maps:get(num_processes, Conf)-1)),
  Conf2 = maps:put(listen_to, ListenTo, Conf),
  Timeout = infinity,
  Runs = test_engine:explore(Engine, bc_module, Conf2,
    MILInstructions, 2, 30, Timeout),
  lists:foreach(fun({RunId, History}) -> io:format("Run ~p: ~p", [RunId,History]) end, Runs).

test_scheduler_pct(InitialConfig) ->
  {ok, Engine} = gen_server:start_link(test_engine, [bc_module, scheduler_pct], []),
  MILInstructions = [],
  Conf = maps:from_list([
    {observers, [causal_delivery]},
    {num_processes, 2},
    {bc_type, causal_broadcast},
    {num_possible_dev_points, 30},
    {size_d_tuple, 5}
  ]
  ++ InitialConfig),
  ListenTo = lists:map(fun(Id) -> "bc" ++ integer_to_list(Id) ++ "_be" end, lists:seq(0, maps:get(num_processes, Conf)-1)),
  Conf2 = maps:put(listen_to, ListenTo, Conf),
  Timeout = infinity,
  Runs = test_engine:explore(Engine, bc_module, Conf2,
    MILInstructions, 2, 30, Timeout),
  lists:foreach(fun({RunId, History}) -> io:format("Run ~p: ~p", [RunId,History]) end, Runs).

