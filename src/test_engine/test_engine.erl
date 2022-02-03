-module(test_engine).
-behaviour(gen_server).
-include("test_engine_types.hrl").
-include("observer_events.hrl").

-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, explore/6, explore/7]).

% a run consists of an id and a history
-type run() :: {pos_integer() | 0, history()}.

-record(state, {
    runs = []:: [run()],
    next_id = 0 :: 0 | pos_integer(),
    bootstrap_scheduler = undefined :: atom(),
    scheduler = undefined :: atom(),
    sut_module :: atom(),
    persist = false :: boolean()
}).

%%% API functions
%% explore
% [Inputs]
% SUTInstructions:: sets:set(instruction()), available API commands of the system under test
% MILInstructions :: sets:set(instruction()), MIL instructions to be used as part of exploration
% Observers :: sets:set(atom()), Observers to be registered
% NumRuns :: number of exploration runs
% Length :: number of steps per run
% 
% [Returns]
% Runs :: [{pos_integer(), history()}]
-spec explore(pid(), atom(), any(), [#abstract_instruction{}], pos_integer(), pos_integer()) -> [{pos_integer(), history()}].
explore(TestEngine, SUTModule, Config, MILInstructions, NumRuns, Length) ->
    gen_server:call(TestEngine,
        {explore, {SUTModule, Config, MILInstructions, NumRuns, Length}}, infinity).
-spec explore(pid(), atom(), any(), [#abstract_instruction{}], pos_integer(), pos_integer(), pos_integer() | infinity) -> [{pos_integer(), history()}].
explore(TestEngine, SUTModule, Config, MILInstructions, NumRuns, Length, Timeout) ->
    gen_server:call(TestEngine,
        {explore, {SUTModule, Config, MILInstructions, NumRuns, Length}}, Timeout).

%% gen_server callbacks
-spec init([atom(), ...]) -> {'ok', #state{}}.
init([SUTModule, Scheduler]) ->
    init([SUTModule, Scheduler, scheduler_vanilla_fifo]);
init([SUTModule, Scheduler, BootstrapScheduler]) when is_atom(BootstrapScheduler)->
    init([SUTModule, Scheduler, BootstrapScheduler, #{}]);
init([SUTModule, Scheduler, Config]) when is_map(Config)->
    init([SUTModule, Scheduler, scheduler_vanilla_fifo, Config]);
init([SUTModule, Scheduler, BootstrapScheduler, Config]) -> 
    Persist = case {maps:get(persist, Config, false), os:getenv("MIL_MNESIA_DIR", "undef")} of
        {false, "undef"} -> false;
        {true, "undef"} ->
            % persistence requested but no db was given -> use default dir "_build/Mnesia_DB"
            setup_db("../../../Mnesia_DB"),
            true;
        {_, Dir} ->
            setup_db(Dir),
            true end,
    %% start pid_name_table
    ets:new(pid_name_table, [named_table, {read_concurrency, true}, ordered_set, public]),
    {ok,#state{
        bootstrap_scheduler = BootstrapScheduler,
        scheduler = Scheduler,
        sut_module = SUTModule,
        persist = Persist
    }}.

handle_cast(_Msg, State) ->
    {noreply, State}.

-spec handle_call({explore, {atom(), #{}, [atom()], 0 | pos_integer(), 0 | pos_integer()}}, _, #state{}) -> {'reply', [{pos_integer(), history()}], #state{}}.
handle_call({explore, {SUTModule, Config, MILInstructions, NumRuns, Length}}, _From, State) ->
    RunIds = lists:seq(State#state.next_id, State#state.next_id+NumRuns-1),
    Runs = lists:foldl(
        fun(RunId, Acc) ->
            [{RunId, explore1(SUTModule, Config, MILInstructions, Length, State, RunId)} | Acc] end,
        [], RunIds),
    {reply, Runs, State#state{
        runs = Runs ++ State#state.runs,
        next_id = State#state.next_id + NumRuns
    }};
handle_call(Msg,_From, State) ->
    erlang:error("[~p] unhandled call ~p from ~p", [?MODULE, Msg]),
    {stop, unhandled_call, State}.

handle_info(Info, State) ->
    io:format("[~p] received info: ~p~n", [?MODULE, Info]),
    {noreply, State}.

terminate(Reason, _State) ->
    io:format("[Test Engine] Terminating. Reason: ~p~n", [Reason]),
    ok.

%%% internal functions

% setup mnesia database
-spec setup_db(nonempty_string()) -> ok.
setup_db(Dir) ->
    logger:info("[~p] starting up mnesia database in dir ~p.", [?MODULE, Dir]),
    application:set_env(mnesia, dir, Dir),
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

% perform a single exploration run
-spec explore1(atom(), #{atom() => any()}, [#abstract_instruction{}], integer(), #state{}, integer()) -> history().
explore1(SUTModule, Config, MILInstructions, Length, State, RunId) ->
    %io:format("[Test Engine] Exploring 1 with Config: ~p, MILInstructions: ~p~n",[Config, MILInstructions]),
    % empty ets table (we use the same name across all)
    ets:delete_all_objects(pid_name_table),
    % start MIL
    {ok, MIL} = message_interception_layer:start(),
    ets:insert(pid_name_table, {MIL, "MIL"}),
    erlang:monitor(process, MIL),
    application:set_env(sched_msg_interception_erlang, msg_int_layer, MIL),

    % create observer manager
    {ok, ObsManager} = gen_event:start({global, om}),

    % start SUTModule
    {ok, SUTModRef} = SUTModule:start(Config),

    % start observers
    Observers = SUTModule:get_observers(),
    lists:foreach(fun(Obs) -> gen_event:add_sup_handler({global, om}, Obs, [Config]) end,
        Observers),

    % bootstrap application w/o scheduler
    SUTModule:bootstrap_wo_scheduler(),

    InitialHistory = [{#instruction{module=test_engine, function=init, args=[]}, collect_state(MIL, SUTModule)}],

    % bootstrap application w/ scheduler if necessary
    History = case SUTModule:needs_bootstrap_w_scheduler() of
        true -> {ok, BootstrapScheduler} = (State#state.bootstrap_scheduler):start(Config),
                CurrHistory = bootstrap_w_scheduler(State, SUTModule, BootstrapScheduler, InitialHistory, MIL, MILInstructions),
                gen_server:stop(BootstrapScheduler),
                CurrHistory;
        false -> InitialHistory
    end,

    % start scheduler
    {ok, Scheduler} = (State#state.scheduler):start(Config),

    % gen sequence of steps
    Steps = lists:seq(0, Length-1),

    % per step: choose instruction, execute and collect result
    Run = lists:foldl(fun(_Step, Hist) ->
            % ask scheduler for next concrete instruction
            NextInstr = (State#state.scheduler):choose_instruction(Scheduler, MIL, SUTModule, MILInstructions, Hist),
            % io:format("[~p] running istruction: ~p~n", [?MODULE, NextInstr]),
            ok = run_instruction(NextInstr, MIL, State),
            % give program a little time to react
            timer:sleep(500),
            ProgState = collect_state(MIL, SUTModule),

            [{NextInstr, ProgState} | Hist] end,
        History, Steps),

    % persist test run in database if requested
    case State#state.persist of
        true ->
            % write to db
            store_run(Run, State#state.scheduler, Config);
        false -> ok end,
    
    % write html file if html output is requested
    case maps:get(html_output, Config, false) of
        false -> ok;
        true ->
            case maps:get(test_name, Config, undefined) of
                undefined -> erlang:throw("Test name undefined but HTML output requested.");
                TestName ->
                    Filename = io_lib:format("~p_~p", [TestName, RunId]),
                    logger:info("[~p] requesting html file generation: ~p", [?MODULE, Filename]),
                    PidNameMap = maps:from_list(ets:tab2list(pid_name_table)),
                    html_output:output_html(Filename, Run, PidNameMap)
            end
    end,

    % write dot files for abstract states if requested
    case maps:get(dot_output, Config, false) of
        false -> ok;
        true ->
            case maps:get(test_name, Config, undefined) of
                undefined -> erlang:throw("Test name undefined but HTML output requested.");
                TestName1 ->
                    logger:info("[~p] requesting dot file generation for abstract states", [?MODULE]),
                    AbstractStates = lists:map(fun({_, ProgState}) -> ProgState#prog_state.abstract_state end, Run),
                    lists:map(
                        fun({AbsStateNum, AbstractState}) ->
                            erlang:display(["TestName1", TestName1, "RunId", RunId, "AbsStateNum", AbsStateNum]),
                            Filename1 = io_lib:format("~p_~p_AbsState_~p", [TestName1, RunId, AbsStateNum]),
                            logger:info("[~p] requesting dot file generation for abstract states in file: ~p", [?MODULE, Filename1]),
                            dot_output:output_dot(Filename1, AbstractState)
                        end,
                        lists:zip(lists:seq(1, length(AbstractStates)), AbstractStates)
                    )
            end
    end,

    ok = SUTModule:stop_sut(),
    gen_server:stop(SUTModRef),

    % clean MIL, Observer Manager, SUT Module and Scheduler
    gen_server:stop(MIL),
    gen_server:stop(Scheduler),
    gen_event:stop(ObsManager),
    % return run
    Run.

-spec run_instruction(#instruction{}, pid(), #state{}) -> ok.
run_instruction(#instruction{module = Module, function = Function, args = Args}, MIL, _State) ->
%%    only spawn new processes for instructions which are not executed by MIL
    case Module == message_interception_layer of
        true -> apply(Module, Function, Args);
        false ->
            _Pid = spawn(fun() ->
                Name = string:concat("run_instr_proc_", integer_to_list(erlang:unique_integer([positive]))),
                message_interception_layer:register_with_name(MIL, Name, self(), run_instr_proc),
                apply(Module, Function, Args),
%%        TODO send result back
                message_interception_layer:deregister(MIL, Name, self())
                         end)
    end,
    ok.

-spec collect_state(pid(), atom()) -> #prog_state{}.
collect_state(MIL, SUTModule) ->
    Observers = gen_event:which_handlers({global,om}),

    % collect properties
    Props = SUTModule:get_properties(),
    Properties = lists:filter(fun(X) -> lists:member(X, Props) end, Observers),
    PropValues = maps:from_list(lists:flatmap(fun(P) -> read_property(P) end, Properties)),

    % collect abstract state 
    {ConcreteState, AbstractState} = case SUTModule:abstract_state_mod() of
        undefined -> {undefined, undefined};
        AbstractStateModule -> gen_event:call({global,om}, AbstractStateModule, get_result) end,

    % collect MIL Stuff: commands in transit, timeouts, nodes, crashed
    #prog_state{
        properties = PropValues,
        commands_in_transit = message_interception_layer:get_commands_in_transit(MIL),
        timeouts = message_interception_layer:get_timeouts(MIL),
        nodes = message_interception_layer:get_all_node_pids(MIL),
        crashed = sets:to_list(message_interception_layer:get_transient_crashed_nodes(MIL)),
        % TODO: support permanent crashes
        concrete_state = ConcreteState,
        abstract_state = AbstractState
    }.

% stores a test run on disk in an mnesia database
-spec store_run(history(), atom(), #{atom() => any()}) -> ok.
-dialyzer({no_return, store_run/3}).
store_run(Run, Scheduler, Config) -> 
    F = fun() ->
        mnesia:write(#mil_test_runs{
            date = erlang:system_time(second),
            testmodule = maps:get(test_module, Config),
            testcase = maps:get(test_name, Config),
            scheduler = Scheduler,
            num_processes = map_get(num_processes, Config),
            length = map_get(run_length, Config),
            history = Run,
            config = Config
        }) end,
    mnesia:activity(transaction, F).

-spec read_property(atom()) -> [{nonempty_string(), boolean()}].
read_property(Observer) ->
    Result = gen_event:call({global,om}, Observer, get_result),
    % check if property is a simple boolean or rather a map of sub_property -> boolean
    case Result of
        Bool when (Bool =:= true) or (Bool =:= false) -> [{atom_to_list(Observer), Bool}];
        Map -> lists:map(fun({Key,Val}) -> {atom_to_list(Observer) ++ "_" ++ Key, Val} end,
            maps:to_list(Map))
    end.

%% does the bootstrapping with the according scheduler and returns initial part of history
-spec bootstrap_w_scheduler(#state{}, atom(), atom(), history(), pid(), [atom()]) -> history().
bootstrap_w_scheduler(State, SUTModule, BootstrapScheduler, History, MIL, MILInstructions) ->
%%    idea:
%% - let SUTModule start the bootstrapping part which is needs instructions to be scheduled
%%    in a process which notifies the TestEngine with result
%% - in parallel, let TestEngine run the scheduled instructions and wait for notification
    ReplyRef = SUTModule:bootstrap_w_scheduler(self()),
    % per step: choose instruction, execute and collect result
    bootstrap_w_scheduler_loop(ReplyRef, History, State, BootstrapScheduler, MIL, SUTModule, MILInstructions).

-spec bootstrap_w_scheduler_loop(_, history(), #state{}, atom(), pid(), atom(), [atom()]) -> history().
bootstrap_w_scheduler_loop(ReplyRef, History, State, BootstrapScheduler, MIL, SUTModule, MILInstructions) ->
    receive
        {ReplyRef, _Result} ->
%%            TODO: gen_event with Result after bootstrap with scheduler
%%            return the History
            History
        after 0 ->
            % ask scheduler for next concrete instruction
            NextInstr = (State#state.bootstrap_scheduler):choose_instruction(BootstrapScheduler, MIL, SUTModule, MILInstructions, History),
            % io:format("[~p] running istruction: ~p~n", [?MODULE, NextInstr]),
            ok = run_instruction(NextInstr, MIL, State),
            % io:format("[~p] commands in transit: ~p~n", [?MODULE, CIT]),
            ProgState = collect_state(MIL, SUTModule),
            History1 = [{NextInstr, ProgState} | History],
            bootstrap_w_scheduler_loop(ReplyRef, History1, State, BootstrapScheduler, MIL, SUTModule, MILInstructions)
    end.

