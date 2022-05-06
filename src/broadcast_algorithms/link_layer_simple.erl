-module(link_layer_simple).
% An implementation of the link layer for testing
% Provides additional methods to simulate node crashes

-behaviour(gen_server).

-export([start/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-record(state, {
    nodes = [] :: [pid()]
}).

%%% API-Functions
-spec start() -> 'ignore' | {'error', _} | {'ok', pid() | {pid(), reference()}}.
start() ->
    gen_server:start_link(?MODULE, [], []).

init([]) ->
    {ok, #state{}}.

%%% Internal Functions
%%  synchronous

% send a message to another node via the link layer
% this message will be delivered via the MIL after a configurable delay
handle_call({send, Data, From, To}, _From, State) ->
    %%% MIL
    message_interception_layer:msg_command(From, To, erlang, send, [To, Data]),
    % Node ! Data,
    %%% LIM
    {reply, ok, State};

% registers client nodes on the link layer, they can afterwards be contacted by other nodes
handle_call({register, Name, R}, _From, State) ->
    NewName = unicode:characters_to_list(Name) ++ "_LL",
    %%% MIL
    message_interception_layer:register_with_name(NewName, R, ll_client_node),
    %%% LIM
    {reply, ok, State#state{nodes=[R|State#state.nodes]}};
% returns all nodes currently on the link layer
handle_call(all_nodes, _From, State) ->
    {reply, {ok, State#state.nodes}, State}.

%%  asynchronous
handle_cast(Msg, State) ->
    io:format("link_layer_simple, unhandled cast message: ~p~n", [Msg]),
    {noreply, State}.

handle_info(Msg, State) ->
    io:format("link_layer_simple unhandled message: ~p~n", [Msg]),
    {noreply, State}.