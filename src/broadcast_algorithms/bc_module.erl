-module(bc_module).
-behaviour(sut_module).
-include("test_engine_types.hrl").

-export([bootstrap/0, get_instructions/0, get_observers/0, generate_instruction/1]).

bc_type() -> application:get_env(sched_msg_interception_erlang, bc_type, causal_broadcast).

get_instructions() -> [#abstract_instruction{module = bc_type(), function = broadcast}].

get_observers() -> [agreement, causal_delivery, no_creation, no_duplications, validity].

-spec bootstrap() -> [pid()].
bootstrap() ->
    NumProcesses = application:get_env(sched_msg_interception_erlang, num_proc, 3),
    DeliverTo = application:get_env(sched_msg_interception_erlang, bc_dlv_to, self()),
    BCType = bc_type(),
    % create link layer
    {ok, LL} = gen_server:start_link(link_layer_simple, [], []),
    % start broadcast processes
    StartBCProcess = fun(Id) ->
        Name = "bc" ++ integer_to_list(Id),
        {ok, Pid} = gen_server:start_link(BCType, [LL, Name, DeliverTo], []),
        Pid end,
    BC_Pids = lists:map(StartBCProcess, lists:seq(0, NumProcesses - 1)),
    application:set_env(sched_msg_interception_erlang, bc_pids, BC_Pids),
    BC_Pids.

generate_instruction(#abstract_instruction{function = broadcast}) ->
    % select random process to broadcast the message
    BC_Pids = application:get_env(sched_msg_interception_erlang, bc_pids, undefined),
    BC = lists:nth(rand:uniform(length(BC_Pids)), BC_Pids),

    #instruction{module = bc_type(), function = broadcast, args = [BC, "Hello World!"]}.