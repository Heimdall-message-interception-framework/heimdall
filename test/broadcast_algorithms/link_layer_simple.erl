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
    {ok, #state{}}.

%%% Internal Functions
%%  synchronous
handle_call({send, Data, Node}, _From, State) ->
    Node ! Data,
    {reply, ok, State};
handle_call({register, R}, _From, State) ->
    {reply, ok, State#state{nodes=[R|State#state.nodes]}};
handle_call(all_nodes, _From, State) ->
    {reply, {ok, State#state.nodes}, State}.

%%  asynchronous
handle_cast(Msg, State) ->
    io:format("link_layer_simple, unhandled cast message: ~p~n", [Msg]),
    {noreply, State}.

handle_info(Msg, State) ->
    io:format("link_layer_simple message: ~p~n", [Msg]),
    {noreply, State}.