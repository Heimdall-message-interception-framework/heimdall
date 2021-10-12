-module('ra-kv-store_module').
-behaviour(sut_module).
-behaviour(gen_server).
-include("test_engine_types.hrl").

-export([bootstrap/0, bootstrap/1, get_instructions/0, get_observers/0, generate_instruction/1, generate_instruction/2]).
-export([start/1, start_link/1, init/1, handle_call/3, handle_cast/2, terminate/2]).

-record(state, {num_processes = 3 :: pos_integer(),
    names = undefined :: [atom()] | undefined,
    nodes = undefined :: [any()] | undefined
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

bootstrap() ->
    gen_server:call('ra-kv-store_module', bootstrap).
bootstrap(Pid) ->
    gen_server:call(Pid, bootstrap).

generate_instruction(AbstrInstruction) ->
    gen_server:call('ra-kv-store_module', {generate_instruction, AbstrInstruction}).
generate_instruction(Pid, AbstrInstruction) ->
    gen_server:call(Pid, {generate_instruction, AbstrInstruction}).

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
handle_call(bootstrap, _From, State) ->
    NumProcesses = State#state.num_processes,
    NameGeneratorFunction = fun(Id) -> "ra_kv" ++ integer_to_list(Id) end,
    Names = lists:map(NameGeneratorFunction, lists:seq(1, NumProcesses)),
%%    TODO: check whether we can omit node()
    NodeNameGeneratorFunc = fun(Name) -> {Name, node()} end,
    Nodes = lists:map(NodeNameGeneratorFunc, lists:seq(1, NumProcesses)),
    ClusterId = <<"ra_kv_store">>,
    Machine = {module, ra_kv_store, #{}}, % last parameter #{} is Config
    application:ensure_all_started(ra),
    ok = ra:start(),
    {ok, _, _} = ra:start_cluster(default, ClusterId, Machine, Nodes),
    {reply, ok, State#state{names = Names, nodes = Nodes}};
%%
handle_call(get_instructions, _From, State) ->
    Instructions = [#abstract_instruction{module = ra_kv_store, function = write},
        #abstract_instruction{module = ra_kv_store, function = read},
        #abstract_instruction{module = ra_kv_store, function = cas}],
    {reply, Instructions, State};
%%
handle_call(generate_instruction, _From, State) ->
    % select a random abstract instruction
    AbstractInstructions = get_instructions(),
    AbsInstr = lists:nth(rand:uniform(length(AbstractInstructions)), AbstractInstructions),
    % select a random process for the instruction
    Names = State#state.names,
    ServerRef = lists:nth(rand:uniform(length(Names)), Names),
    Args = case AbsInstr#abstract_instruction.function of
        write -> % ServerRef :: name(), Key :: integer(), Value :: integer()
            [ServerRef, get_integer(), get_integer()];
        read -> % ServerRef :: name(), Key :: integer())
            [ServerRef, get_integer()];
        cas -> % ServerRef :: name(), Key :: integer(), Value :: integer()
            [ServerRef, get_integer(), get_integer()]
    end,
    Instruction = #instruction{module = AbsInstr#abstract_instruction.module,
        function = AbsInstr#abstract_instruction.function,
        args = Args},
    {reply,
        Instruction,
        State}.
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
