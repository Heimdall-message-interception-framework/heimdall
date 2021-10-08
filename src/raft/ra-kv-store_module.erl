-module('ra-kv-store_module').
-behaviour(sut_module).
-include("test_engine_types.hrl").

-export([bootstrap/1, get_instructions/1, get_observers/1, generate_instruction/2]).

-record(config, {num_processes = 3 :: pos_integer(),
    names = undefined :: [atom()],
    nodes = undefined :: [any()]
}).

get_instructions(_Config) -> [#abstract_instruction{module = ra_kv_store, function = write},
                       #abstract_instruction{module = ra_kv_store, function = read},
                       #abstract_instruction{module = ra_kv_store, function = cas}].

get_observers(_Config) -> [
    raft_election_safety,
    raft_leader_append_only,
    raft_leader_completeness,
    raft_log_matching,
    raft_state_machine_safety,
    raft_template
].

-spec bootstrap(#config{}) -> #config{}.
bootstrap(Config) ->
    NumProcesses = application:get_env(sched_msg_interception_erlang, num_proc, 3),
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
    Config#config{names = Names, nodes = Nodes}.


generate_instruction(#abstract_instruction{},
    #config{names = Names} = Config) ->
    % select a random abstract instruction
    AbstractInstructions = get_instructions(Config),
    AbsInstr = lists:nth(rand:uniform(length(AbstractInstructions)), AbstractInstructions),
    % select a random process for the instruction
    ServerRef = lists:nth(rand:uniform(length(Names)), Names),
    Args = case AbsInstr#abstract_instruction.function of
        write -> % ServerRef :: name(), Key :: integer(), Value :: integer()
            [ServerRef, get_integer(), get_integer()];
        read -> % ServerRef :: name(), Key :: integer())
            [ServerRef, get_integer()];
        cas -> % ServerRef :: name(), Key :: integer(), Value :: integer()
            [ServerRef, get_integer(), get_integer()]
    end,
    {#instruction{module = AbsInstr#abstract_instruction.module,
                 function = AbstractInstructions#abstract_instruction.function,
                 args = Args}, Config}.

get_integer() ->
    rand:uniform(10).
