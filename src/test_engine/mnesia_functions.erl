-module(mnesia_functions).
% functions for leaving an mnesia master node running
-include("test_engine_types.hrl").
-include("raft_abstraction_types.hrl").
-export([setup_db/0, start_master/1]).

% @doc Used to start an mnesia master node.
start_master(Mnesia_Dir) ->
    net_kernel:start([master, shortnames]),
    [Name, Host] = string:split(atom_to_list(node()), "@"),
    My_Dir = unicode:characters_to_list(io_lib:format("~s/~s/",  [Mnesia_Dir, Name])),
    io:format("[~s] My dir is ~p~n", [Name, My_Dir]),
    application:set_env(mnesia, dir, My_Dir),

    case mnesia:create_schema([node()]) of
        ok ->
            io:format("[~s] created schema~n", [Name]),
            application:start(mnesia),
            mnesia:create_table(tree_hashes, [{attributes, record_info(fields, tree_hashes)},
                {disc_copies, [node()]}, {type, set}]),
            mnesia:create_table(mil_test_runs, [{attributes,
                record_info(fields, mil_test_runs)}, {disc_copies, [node()]}, {type, set},
                {index, [#mil_test_runs.scheduler, #mil_test_runs.testcase]}
                ]);
        {error,{_,{already_exists,_}}} ->
            io:format("[~s] schema already exists~n", [Name]),
            application:start(mnesia);
        Error -> logger:error("[~p] unknown error: ~p", [?MODULE, Error]) end,
    mnesia:wait_for_tables([mil_test_runs], 10000).

%% @doc Sets up the mnesia database that is needed to store test runs.
%% If the MIL_MNESIA_DIR env variable is set or an mnesia dir is set manually, the database is started on this node. Otherwise we assume that an mnesia node called "master" is already running.
-spec setup_db() -> ok.
setup_db() ->
    case {os:getenv("MIL_MNESIA_DIR", "undef"), application:get_env(mnesia, dir, "undef")} of
        {"undef", "undef"} ->
            logger:info("[~p ] No directory specified. Assuming master node is running."),
            [_Name, Host] = string:split(atom_to_list(node()), "@"),
            MasterAtom = list_to_atom("master@"++Host),
            application:start(mnesia),
            {ok, [MasterAtom]} = mnesia:change_config(extra_db_nodes, [MasterAtom]);
        {D, "undef"} -> start_local_db(D);
        {"undef", D} -> start_local_db(D);
        {D1, _D2} -> start_local_db(D1) end,
    % wait for table to become ready
    mnesia:wait_for_tables([mil_test_runs], 10000),
    Size = mnesia:table_info(mil_test_runs, size),
    logger:info("[~p] Started mnesia succesfully. Current number of entries: ~p.",
        [?MODULE, Size]),
    ok.

%% @doc Used to start a local mnesia database in case no master node is running.
start_local_db(Dir) ->
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
        Error -> logger:error("[~p] unknown error: ~p", [?MODULE, Error]) end.