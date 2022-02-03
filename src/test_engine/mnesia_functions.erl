-module(mnesia_functions).
% functions for leaving an mnesia master node running
-include("test_engine_types.hrl").
-export([setup_db/0]).

-spec setup_db() -> ok.
setup_db() ->
    Dir = case {os:getenv("MIL_MNESIA_DIR", "undef"), application:get_env(mnesia, dir, "undef")} of
        {"undef", "undef"} -> application:get_env(mnesia, dir, "undef");
        {D, _} -> D;
        {"undef", D} -> D end,
    logger:info("[~p] starting mnesia database in dir ~p.", [?MODULE, Dir]),
    application:set_env(mnesia, dir, Dir),
    % try to set up a schema containing only this node
    case mnesia:create_schema([node()]) of
        ok ->
            application:start(mnesia),
            mnesia:create_table(mil_test_runs, [{attributes,
                record_info(fields, mil_test_runs)}, {disc_copies, [node()]}, {type, set},
                {index, [#mil_test_runs.scheduler, #mil_test_runs.testcase]}
                ]);
        {error,{_,{already_exists,_}}} -> application:start(mnesia);
        Error -> logger:error("[~p] unknown error: ~p", [?MODULE, Error]) end,
    % wait for table to become ready
    mnesia:wait_for_tables([mil_test_runs], 10000),
    Size = mnesia:table_info(mil_test_runs, size),
    logger:info("[~p] Started mnesia succesfully. Current number of entries: ~p.",
        [?MODULE, Size]),
    ok.