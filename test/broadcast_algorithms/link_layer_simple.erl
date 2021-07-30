-module(link_layer_simple).
% An implementation of the link layer for testing
% Provides additional methods to simulate node crashes

-behaviour(gen_server).

-export([start/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-record(state, {
    nodes = [] :: [pid()],
    network = undefined :: pid()
}).

%%% API-Functions
-spec start() -> 'ignore' | {'error', _} | {'ok', pid() | {pid(), reference()}}.
start() ->
    gen_server:start_link(?MODULE, [], []).

init([]) ->
    %%% MIL
    MIL = application:get_env(sched_msg_interception_erlang, msg_int_layer, undefined),
    case MIL of
        undefined -> erlang:error("MIL not found in env!");
        _ -> 
            message_interception_layer:register_with_name(MIL, ll, self(), link_layer_simple)
    end,
    %%% LIM
    {ok, #state{}}.

%%% Internal Functions
%%  synchronous

% send a message to another node via the link layer
% this message will be delivered via the MIL
handle_call({send, Data, Node}, _From, State) ->
    %%% MIL
    MIL = application:get_env(sched_msg_interception_erlang, msg_int_layer, undefined),
    case MIL of
        undefined -> erlang:error("MIL not found in env!");
        _ -> 
            message_interception_layer:msg_command(MIL, self(), Node, erlang, send, [Node, Data])
    end,
    % Node ! Data,
    %%% LIM
    {reply, ok, State};

% registers client nodes on the link layer, they can afterwards be contacted by other nodes
handle_call({register, Name, R}, _From, State) ->
    NewName = list_to_atom(atom_to_list(Name) ++ pid_to_list(R)),
    MIL = application:get_env(sched_msg_interception_erlang, msg_int_layer, undefined),
    case MIL of
        undefined -> erlang:error("MIL not found in env!");
        _ -> 
            message_interception_layer:register_with_name(MIL, NewName, R, ll_client_node)
    end,
% returns all nodes currently on the link layer

%%  asynchronous
handle_cast(Msg, State) ->
    io:format("link_layer_simple, unhandled cast message: ~p~n", [Msg]),
    {noreply, State}.

handle_info(Msg, State) ->
    io:format("link_layer_simple unhandled message: ~p~n", [Msg]),
    {noreply, State}.