-module(best_effort_broadcast_paper).
%% best effort broadcast inspired by [Zeller2020](https://doi.org/10.1145/3406085.3409009)

-behavior(gen_server).

-export([start_link/2, broadcast/2]).

% gen_server callbacks
-export([handle_call/3, handle_cast/2, handle_info/2, init/1, terminate/2]).

-record(state, {
	link_layer	:: pid(), % link layer
	deliver_to	:: pid(), % receiver
	self		:: atom() % name of local process
}).

start_link(LinkLayer, RespondTo) ->
	gen_server:start_link(?MODULE, [LinkLayer, RespondTo], []).

% broadcasts a message to all other nodes that we are connected to
broadcast(B, Msg) ->
	% erlang:display("Broadcasting: ~p~n", [Msg]),
	gen_server:call(B, {broadcast, Msg}).

init([LL, R]) ->
	{ok, #state{
		link_layer = LL,
		deliver_to = R,
		self = self()
	}}.

handle_call({broadcast, Msg}, _From, State) ->
	% deliver locally
	LocalNode = State#state.deliver_to,
    io:format("broadcasting message locally: ~p~n", [Msg]),
	LocalNode ! {deliver, Msg},
	% broadcast to everyone
	LL = State#state.link_layer,
	{ok, AllNodes} = link_layer:all_nodes(LL),
	[link_layer:send(LL, {deliver, Msg}, Node) || Node <- AllNodes, Node =/= LocalNode],
	{reply, ok, State}.

handle_info(Msg, State) ->
    io:format("best_effort_bc_paper message: ~p~n", [Msg]),
	{noreply, State}.

handle_cast(Msg, State) ->
	% we don't do asynchronous requests.
    io:format("best_effort_bc_paper, unhandled cast message: ~p~n", [Msg]),
	{noreply, State}.

terminate(_Reason, _State) ->
	ok.