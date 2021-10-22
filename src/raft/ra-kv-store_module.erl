-module('ra-kv-store_module').
-behaviour(sut_module).
-behaviour(gen_server).
-include("test_engine_types.hrl").

-export([bootstrap_wo_scheduler/0, bootstrap_wo_scheduler/1, get_instructions/0, get_observers/0, generate_instruction/1, generate_instruction/2, bootstrap_w_scheduler/1, bootstrap_w_scheduler/2, needs_bootstrap_w_scheduler/0, stop_sut/0, stop_sut/1]).
-export([start/1, start_link/1, init/1, handle_call/3, handle_cast/2, terminate/2]).

-record(state, {num_processes = 3 :: pos_integer(),
    names = undefined :: [atom()] | undefined,
    nodes = undefined :: [any()] | undefined,
    clusterid = undefined :: any() | undefined,
    machine = undefined :: any() | undefined
}).

%%% API

-spec start(_) -> 'ignore' | {'error', _} | {'ok', pid()}.
start(Config) ->
    gen_server:start({local, 'ra-kv-store_module'}, ?MODULE, [Config], []).

-spec start_link(_) -> 'ignore' | {'error', _} | {'ok', pid()}.
start_link(Config) ->
    gen_server:start_link({local, 'ra-kv-store_module'}, ?MODULE, [Config], []).

get_instructions() ->
    gen_server:call('ra-kv-store_module', get_instructions).

get_observers() -> [
    raft_election_safety,
    raft_leader_append_only,
    raft_leader_completeness,
    raft_log_matching,
    raft_state_machine_safety,
    raft_template
].

bootstrap_wo_scheduler() ->
    gen_server:call(?MODULE, bootstrap_wo_scheduler).
bootstrap_wo_scheduler(Pid) ->
    gen_server:call(Pid, bootstrap_wo_scheduler).

needs_bootstrap_w_scheduler() ->
    true.

bootstrap_w_scheduler(TestEngine) ->
    gen_server:call(?MODULE, {bootstrap_w_scheduler, TestEngine}).
bootstrap_w_scheduler(Pid, TestEngine) ->
    gen_server:call(Pid, {bootstrap_w_scheduler, TestEngine}).

generate_instruction(AbstrInstruction) ->
    gen_server:call('ra-kv-store_module', {generate_instruction, AbstrInstruction}).
generate_instruction(Pid, AbstrInstruction) ->
    gen_server:call(Pid, {generate_instruction, AbstrInstruction}).

stop_sut() ->
    gen_server:call('ra-kv-store_module', stop_sut).
stop_sut(Pid) ->
    gen_server:call(Pid, stop_sut).

%%% gen server callbacks
-spec init([Args :: term()]) ->
    {ok, State :: term()} | {ok, State :: term(), timeout() | hibernate | {continue, term()}} |
    {stop, Reason :: term()} | ignore.
init([Config]) ->
    {ok, #state{
        num_processes = maps:get(num_processes, Config, 3)
    }}.

-spec handle_call(Request :: term(), From :: {pid(), Tag :: term()},
    State :: term()) ->
    {reply, Reply :: term(), NewState :: term()} |
    {reply, Reply :: term(), NewState :: term(), timeout() | hibernate | {continue, term()}} |
    {noreply, NewState :: term()} |
    {noreply, NewState :: term(), timeout() | hibernate | {continue, term()}} |
    {stop, Reason :: term(), Reply :: term(), NewState :: term()} |
    {stop, Reason :: term(), NewState :: term()}.
handle_call(bootstrap_wo_scheduler, _From, State) ->
    NumProcesses = State#state.num_processes,
    NameGeneratorFunction = fun(Id) -> list_to_atom("ra_kv" ++ integer_to_list(Id)) end,
    Names = lists:map(NameGeneratorFunction, lists:seq(1, NumProcesses)),
%%    TODO: check whether we can omit node()
    NodeNameGeneratorFunc = fun(Num) -> {NameGeneratorFunction(Num), node()} end,
    Nodes = lists:map(NodeNameGeneratorFunc, lists:seq(1, NumProcesses)),
    ClusterId = <<"ra_kv_store">>,
    Machine = {module, ra_kv_store, #{}}, % last parameter #{} is Config
    application:ensure_all_started(ra),
    ok = ra:start(),
%%    TODO: linked?
    {reply, ok, State#state{names = Names, nodes = Nodes, clusterid = ClusterId, machine = Machine}};
%%
handle_call({bootstrap_w_scheduler, TestEngine}, _From, #state{clusterid = ClusterId, machine = Machine, nodes = Nodes} = State) ->
    ReplyRef = make_ref(),
    _ProcBuildingCluster = spawn(fun() ->
        Result = ra:start_cluster(default, ClusterId, Machine, Nodes),
        erlang:display(["cluster_build?", Result]),
        TestEngine ! {ReplyRef, Result}
    end),
    {reply, ReplyRef, State};
%%
handle_call(get_instructions, _From, State) ->
    Instructions = [#abstract_instruction{module = ra_kv_store, function = write},
        #abstract_instruction{module = ra_kv_store, function = read},
        #abstract_instruction{module = ra_kv_store, function = cas}],
    {reply, Instructions, State};
%%
handle_call({generate_instruction, AbsInstr}, _From, State) ->
    % select a random abstract instruction
%%    AbstractInstructions = get_instructions(),
%%    AbsInstr = lists:nth(rand:uniform(length(AbstractInstructions)), AbstractInstructions),
    % select a random process for the instruction
    Names = State#state.names,
    ServerRef = lists:nth(rand:uniform(length(Names)), Names),
    Args = case AbsInstr#abstract_instruction.function of
        write -> % ServerRef :: name(), Key :: integer(), Value :: integer()
            [ServerRef, get_integer(), get_integer()];
        read -> % ServerRef :: name(), Key :: integer())
            [ServerRef, get_integer()];
        cas -> % ServerRef :: name(), Key :: integer(), Value :: integer()
            [ServerRef, get_integer(), get_integer(), get_integer()];
        _ -> % undefined
           erlang:throw("unknown abstract instruction for ra_kv_store")
    end,
    Instruction = #instruction{module = AbsInstr#abstract_instruction.module,
        function = AbsInstr#abstract_instruction.function,
        args = Args},
    {reply,
        Instruction,
        State};
%%
handle_call(stop_sut, _From, State) ->
    Result = application:stop(ra),
    {reply, Result, State}.
%%
-spec handle_cast(Request :: term(), State :: term()) ->
    {noreply, NewState :: term()} |
    {noreply, NewState :: term(), timeout() | hibernate | {continue, term()}} |
    {stop, Reason :: term(), NewState :: term()}.
handle_cast(_Req, _State) ->
    io:format("unhandled request in ra-kv-store_module: ~p", _Req),
    {noreply, _State}.

-spec terminate(Reason :: (normal | shutdown | {shutdown, term()} | term()), State :: term()) ->
    term().
terminate(Reason, _State) ->
    io:format("Terminating. Reason: ~p~n", [Reason]),
    ok.

%% internal helper functions
get_integer() ->
    rand:uniform(10).
