-module(test_engine).
-behaviour(gen_server).
-include("test_engine_types.hrl").
-include("observer_events.hrl").

-export([init/1, handle_call/3, handle_cast/2, terminate/2, explore/3, explore/6, explore/7]).

% a run consists of an id and a history
-type run() :: {pos_integer(), history()}.

-record(state, {
    runs = []:: [run()],
    next_id = 0 :: 0 | pos_integer(),
    scheduler = undefined :: atom(),
    sut_module :: atom()
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
        {explore, {SUTModule, Config, MILInstructions, NumRuns, Length}}).
-spec explore(pid(), atom(), any(), [#abstract_instruction{}], pos_integer(), pos_integer(), pos_integer() | infinity) -> [{pos_integer(), history()}].
explore(TestEngine, SUTModule, Config, MILInstructions, NumRuns, Length, Timeout) ->
    gen_server:call(TestEngine,
        {explore, {SUTModule, Config, MILInstructions, NumRuns, Length}}, Timeout).
explore(TestEngine, NumRuns, Length) ->
    undefined.

%% gen_server callbacks
init([SUTModule, Scheduler]) ->
    {ok,#state{
        scheduler = Scheduler,
        sut_module = SUTModule
    }}.

handle_cast(_Msg, State) ->
    {noreply, State}.

-spec handle_call({explore, _}, _, #state{}) -> {'reply', [{pos_integer(), history()}], #state{}}.
handle_call({explore, {SUTModule, Config, MILInstructions, NumRuns, Length}}, _From, State) ->
    RunIds = lists:seq(State#state.next_id, State#state.next_id+NumRuns),
    Runs = lists:foldl(
        fun(RunId, Acc) ->
            [{RunId, explore1(SUTModule, Config, MILInstructions, Length, State)} | Acc] end,
        [], RunIds),
    {reply, Runs, State#state{
        runs = Runs ++ State#state.runs,
        next_id = State#state.next_id + NumRuns
    }};
handle_call(Msg,_From, State) ->
    erlang:error("[~p] unhandled call ~p from ~p", [?MODULE, Msg]),
    {stop, unhandled_call, State}.

terminate(Reason, _State) ->
    io:format("[Test Engine] Terminating. Reason: ~p~n", [Reason]),
    ok.
%%% internal functions
% perform a single exploration run
-spec explore1(atom(), maps:map(), [#abstract_instruction{}], integer(), #state{}) -> history().
explore1(SUTModule, Config, MILInstructions, Length, State) ->
    %io:format("[Test Engine] Exploring 1 with Config: ~p, MILInstructions: ~p~n",[Config, MILInstructions]),
    % start MIL 
    {ok, MIL} = message_interception_layer:start(),
    application:set_env(sched_msg_interception_erlang, msg_int_layer, MIL),
    
    % create observer manager
    {ok, ObsManager} = gen_event:start({global, om}),

    % start SUTModule
    {ok, SUTModRef} = SUTModule:start(Config),

    % start scheduler
    {ok, Scheduler} = (State#state.scheduler):start(Config),

    % start observers
    Observers = SUTModule:get_observers(),
    lists:foreach(fun(Obs) -> gen_event:add_handler({global, om}, Obs, []) end,
        Observers),

    % bootstrap application
    SUTModule = State#state.sut_module,
    SUTModule:bootstrap(),

    % gen sequence of steps
    Steps = lists:seq(0, Length-1),

    InitialHistory = [{init, collect_state(MIL, Observers)}],
    % per step: choose instruction, execute and collect result
    Run = lists:foldl(fun(_Step, History) ->
            % ask scheduler for next concrete instruction
            NextInstr = (State#state.scheduler):choose_instruction(Scheduler, MIL, SUTModule, MILInstructions, History),
            % io:format("[~p] running istruction: ~p~n", [?MODULE, NextInstr]),
            ok = run_instruction(NextInstr, State),
            % io:format("[~p] commands in transit: ~p~n", [?MODULE, CIT]),
            ProgState = collect_state(MIL, Observers),

            [{NextInstr, ProgState} | History] end,
        InitialHistory, Steps),
    
    % clean MIL, Observer Manager, SUT Module and Scheduler
    gen_server:stop(MIL),
    gen_event:stop(ObsManager),
    gen_server:stop(SUTModRef),
    gen_server:stop(Scheduler),
    % return run
    Run.

-spec run_instruction(#instruction{}, #state{}) -> ok.
run_instruction(#instruction{module = Module, function = Function, args = Args}, _State) ->
    apply(Module, Function, Args),
    ok.

-spec collect_state(pid(), [atom()]) -> #prog_state{}.
collect_state(MIL, Observers) ->
    % collect properties
    % TODO: collect properties 

    % collect MIL Stuff: commands in transit, timeouts, nodes, crashed
    #prog_state{
        commands_in_transit = message_interception_layer:get_commands_in_transit(MIL),
        timeouts = message_interception_layer:get_timeouts(MIL),
        nodes = message_interception_layer:get_all_node_names(MIL),
        crashed = sets:to_list(message_interception_layer:get_transient_crashed_nodes(MIL))
        % TODO: support permanent crashes
    }.
