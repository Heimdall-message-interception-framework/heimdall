-module(bc_module).
-behaviour(sut_module).
-behaviour(gen_server).
-include("test_engine_types.hrl").

-export([generate_instruction/2, bootstrap/1, start/1, start_link/1, bootstrap/0, get_instructions/0, get_observers/0, generate_instruction/1]).
-export([init/1, handle_call/3, handle_cast/2, terminate/2]).

-record(state, {num_processes = 3 :: pos_integer(),
                 dlv_to :: pid(),
                 bc_type = causal_broadcast :: atom(),
                 bc_pids :: undefined | [pid()]}).

%%% API
-spec start_link(_) -> {'ok', pid()}.
start_link(Config) ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [Config], []).

start(Config) ->
    gen_server:start({local, ?MODULE}, ?MODULE, [Config], []).

get_instructions() ->
    gen_server:call(?MODULE, get_instructions).

get_observers() -> [agreement, causal_delivery, no_creation, no_duplications, validity].

bootstrap() ->
    gen_server:call(?MODULE, bootstrap).
bootstrap(Pid) ->
    gen_server:call(Pid, bootstrap).
generate_instruction(AbstrInstruction) ->
    gen_server:call(?MODULE, {generate_instruction, AbstrInstruction}).
generate_instruction(Pid, AbstrInstruction) ->
    gen_server:call(Pid, {generate_instruction, AbstrInstruction}).

%%% gen server callbacks
init([Config]) ->
    io:format("[~p] starting with config: ~p~n",[?MODULE, Config]),
    {ok, #state{
        num_processes = maps:get(num_processes, Config, 3),
        dlv_to = maps:get(dlv_to, Config, self()),
        bc_type = maps:get(bc_type, Config, causal_broadcast)
    }}.

handle_call(bootstrap, _From, State) ->
    NumProcesses = State#state.num_processes,
    DeliverTo = State#state.dlv_to,
    BCType = State#state.bc_type,
    % create link layer
    {ok, LL} = gen_server:start_link(link_layer_simple, [], []),
    % start broadcast processes
    StartBCProcess = fun(Id) ->
        Name = "bc" ++ integer_to_list(Id),
        {ok, Pid} = gen_server:start_link(BCType, [LL, Name, DeliverTo], []),
        Pid end,
    BC_Pids = lists:map(StartBCProcess, lists:seq(0, NumProcesses - 1)),
    application:set_env(sched_msg_interception_erlang, bc_pids, BC_Pids),
    {reply, ok, State#state{bc_pids = BC_Pids}};
handle_call({generate_instruction, #abstract_instruction{function = broadcast}}, _From, State) ->
    % select random process to broadcast the message
    BC_Pids = State#state.bc_pids,
    BC = lists:nth(rand:uniform(length(BC_Pids)), BC_Pids),

    Module = State#state.bc_type,
    Instr = #instruction{module = Module, function = broadcast, args = [BC, "Hello World!"]},
    {reply, Instr, State};
handle_call(get_instructions, _From, State) ->
    Module = State#state.bc_type,
    Instructions = [#abstract_instruction{module = Module, function = broadcast}],
    {reply, Instructions, State}.

handle_cast(_Req, _State) ->
    {noreply, _State}.


terminate(Reason, _State) ->
    io:format("[BC_Module] Terminating. Reason: ~p~n", [Reason]),
    ok.