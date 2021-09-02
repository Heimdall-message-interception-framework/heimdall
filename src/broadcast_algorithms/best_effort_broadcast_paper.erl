-module(best_effort_broadcast_paper).
%% best effort broadcast inspired by [Zeller2020](https://doi.org/10.1145/3406085.3409009)

-behavior(gen_server).

-export([start_link/3, broadcast/2]).

% gen_server callbacks
-export([handle_call/3, handle_cast/2, handle_info/2, init/1, terminate/2]).

-record(state, {
	link_layer	:: pid(), % link layer
	deliver_to	:: pid(), % receiver
	self		:: atom() % name of local process
}).

-spec start_link(pid(), atom(), pid()) -> {'error', _} | {'ok', bc_types:broadcast()}.
start_link(LinkLayer, ProcessName, RespondTo) ->
	gen_server:start_link(?MODULE, [LinkLayer, ProcessName, RespondTo], []).

% broadcasts a message to all other nodes that we are connected to
-spec broadcast(bc_types:broadcast(), bc_types:message()) -> any().
broadcast(B, Msg) ->
	% erlang:display("Broadcasting: ~p~n", [Msg]),
	gen_server:call(B, {broadcast, Msg}).

init([LL, Name, R]) ->
	% register at link layer in order to receive broadcasts from others
	link_layer:register(LL, Name, self()),
	{ok, #state{
		link_layer = LL,
		deliver_to = R,
		self = unicode:characters_to_list([Name| "_be"])
	}}.

-spec handle_call({'broadcast', bc_types:message()}, _, #state{link_layer::pid(), deliver_to::pid(), self::atom()}) -> {'reply', 'ok', #state{link_layer::pid(), deliver_to::pid(), self::atom()}}.
handle_call({broadcast, Msg}, _From, State) ->
	% deliver locally
	State#state.deliver_to ! {deliver, Msg},
	% broadcast to everyone
	LL = State#state.link_layer,
	{ok, AllNodes} = link_layer:all_nodes(LL),
	[link_layer:send(LL, {deliver, Msg}, self(), Node) || Node <- AllNodes, Node =/= self()],
	{reply, ok, State}.

-spec handle_info({deliver, bc_types:message()}, _) -> {'noreply', _}.
handle_info({deliver, Msg}, State) ->
	State#state.deliver_to ! {deliver, Msg},
	{noreply, State};
handle_info(Msg, State) ->
    io:format("[best_effort_bc_paper] received unknown message: ~p~n", [Msg]),
	{noreply, State}.

handle_cast(Msg, State) ->
    io:format("[best_effort_bc_paper] received unhandled cast: ~p~n", [Msg]),
	{noreply, State}.

terminate(_Reason, _State) ->
	ok.