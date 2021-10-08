-module(bc_module).
-behaviour(sut_module).
-include("test_engine_types.hrl").

-export([bootstrap/1, get_instructions/1, get_observers/1, generate_instruction/2]).

-record(config, {num_processes = 3 :: pos_integer(),
                 dlv_to :: pid(),
                 bc_type = causal_broadcast :: atom(),
                 bc_pids :: [pid()]}).

get_instructions(Config) ->
    Module = Config#config.bc_type,
    [#abstract_instruction{module = Module, function = broadcast}].

get_observers(_Config) -> [agreement, causal_delivery, no_creation, no_duplications, validity].

-spec bootstrap(#config{}) -> #config{}.
bootstrap(Config) ->
    NumProcesses = Config#config.num_processes,
    DeliverTo = self(),
    BCType = Config#config.bc_type,
    % create link layer
    {ok, LL} = gen_server:start_link(link_layer_simple, [], []),
    % start broadcast processes
    StartBCProcess = fun(Id) ->
        Name = "bc" ++ integer_to_list(Id),
        {ok, Pid} = gen_server:start_link(BCType, [LL, Name, DeliverTo], []),
        Pid end,
    BC_Pids = lists:map(StartBCProcess, lists:seq(0, NumProcesses - 1)),
    application:set_env(sched_msg_interception_erlang, bc_pids, BC_Pids),
    Config#config{bc_pids = BC_Pids}.

generate_instruction(#abstract_instruction{function = broadcast}, Config) ->
    % select random process to broadcast the message
    BC_Pids = Config#config.bc_pids,
    BC = lists:nth(rand:uniform(length(BC_Pids)), BC_Pids),

    Module = Config#config.bc_type,
    {#instruction{module = Module, function = broadcast, args = [BC, "Hello World!"]}, Config}.