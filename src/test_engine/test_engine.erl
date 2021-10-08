-module(test_engine).
-behaviour(gen_server).
-include("test_engine_types.hrl").
-include("observer_events.hrl").

-export([init/1, handle_call/3, handle_cast/2, explore/6]).

% SUT Bootstrapping Module: starts and bootstraps all necessary applications processes
% ?MODULE:bootstrap()

% SUT Instruction Module: 
% ?MODULE:run_instruction(Instruction)

% a run consists of an id and a history
-type run() :: {pos_integer(), history()}.

-record(state, {
    runs = []:: [run()],
    next_id = 0 :: 0 | pos_integer(),
    scheduler = undefined :: atom(),
    sut_module :: atom()
}).

% explore 1 run
% explore1(SUTInstruction, MILInstructions, Observers, NumRuns) ->

%% API functions

% [Inputs]
% SUTInstructions:: sets:set(instruction()), available API commands of the system under test
% MILInstructions :: sets:set(instruction()), MIL instructions to be used as part of exploration
% Observers :: sets:set(atom()), Observers to be registered
% NumRuns :: number of exploration runs
% Length :: number of steps per run
% 
% [Returns]
% Runs :: [{pos_integer(), history()}]
-spec explore(pid(), [#abstract_instruction{}], [any()], [atom()], pos_integer(), pos_integer()) -> [{pos_integer(), history()}].
explore(TestEngine, SUTInstructions, MILInstructions, Observers, NumRuns, Length) ->
    gen_server:call(TestEngine,
        {explore, {SUTInstructions, MILInstructions, Observers, NumRuns, Length}}).

%% gen_server callbacks
init([SUTModule, Scheduler]) ->
    % create observer manager
    {ok, _ObsManager} = gen_event:start_link({global, om}),

    {ok,#state{
        scheduler = Scheduler,
        sut_module = SUTModule
    }}.

handle_cast(_Msg, State) ->
    {noreply, State}.

-spec handle_call({explore, _}, _, #state{}) -> {'reply', [{pos_integer(), history()}], #state{}}.
handle_call({explore, {SUTInstructions, MILInstructions, Observers, NumRuns, Length}}, _From, State) ->
    RunIds = lists:seq(State#state.next_id, State#state.next_id+NumRuns),
    Runs = lists:foldl(
        fun(RunId, Acc) ->
            [{RunId, explore1(SUTInstructions, MILInstructions, Observers, Length, State)} | Acc] end,
        [], RunIds),
    {reply, Runs, State#state{
        runs = Runs ++ State#state.runs,
        next_id = State#state.next_id + NumRuns
    }};
handle_call(_Msg,_From, State) ->
    {reply, ok, State}.

%% internal functions
% perform a single exploration run
explore1(SUTInstructions, MILInstructions, Observers, Length, State) ->
    % TODO: start MIL
    % {ok, MIL} = message_interception_layer:start(Scheduler),
    % application:set_env(sched_msg_interception_erlang, msg_int_layer, MIL),
    % gen_server:cast(Scheduler, {register_message_interception_layer, MIL}),
    % gen_server:cast(MIL, {start}),
    
    % start observers
    lists:foreach(fun(Obs) -> gen_event:add_handler({global, om}, Obs, []) end,
        Observers),

    % bootstrap application
    SUTModule = State#state.sut_module,
    SUTModule:bootstrap(),
    
    % gen sequence of steps
    Steps = lists:seq(0, Length-1),
    % per step: choose instruction, execute and collect result
    lists:foldl(fun(_Step, History) ->
            Scheduler = State#state.scheduler,
            % TODO: let scheduler choose instruction
            % NextInstr = Scheduler:choose_instruction(MIL, SUTInstructions, MILInstructions, History),
            % case split depending on type of instruction: MIL/SUT
            NextInstr = #abstract_instruction{module = causal_broadcast, function = broadcast},
            ConcreteInstr = run_instruction(NextInstr, State),
            % SUT: run_instruction(NextInstr),
            % MIL: TODO
            % TODO: collect programm state
            % ProgState = collect_state(MIL, Observers),
            ProgState = undefined,

            [{ConcreteInstr, ProgState} | History] end,
        [], Steps).

-spec run_instruction(#abstract_instruction{}, #state{}) -> #instruction{}.
run_instruction(AbstractInstr, State) ->
    SUTModule = State#state.sut_module,
    ConcreteInstr =
        SUTModule:generate_instruction(AbstractInstr),
    apply(ConcreteInstr#instruction.module, ConcreteInstr#instruction.function, ConcreteInstr#instruction.args),
    ConcreteInstr.

% TODO: collect_state
-spec collect_state(pid(), [atom()]) -> undefined.
collect_state(MIL, Observers) -> undefined.