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

start_link(LinkLayer, ProcessName, RespondTo) ->
	gen_server:start_link(?MODULE, [LinkLayer, ProcessName, RespondTo], []).

% broadcasts a message to all other nodes that we are connected to
broadcast(B, Msg) ->
	erlang:display(["Broadcasting: ~p~n", Msg]),
	gen_server:call(B, {broadcast, Msg}).

init([LL, Name, R]) ->
	% register at link layer in order to receive broadcasts from others
	link_layer:register(LL, Name, self()),
	{ok, #state{
		link_layer = LL,
		deliver_to = R,
		self = Name
	}}.

handle_call({broadcast, Msg}, _From, State) ->
	% deliver locally
	LocalNode = State#state.deliver_to,
	LocalNode ! Msg,
	% broadcast to everyone
	LL = State#state.link_layer,
	{ok, AllNodes} = link_layer:all_nodes(LL),
	[link_layer:send(LL, Msg, Node) || Node <- AllNodes, Node =/= self()],
	{reply, ok, State}.

handle_info({deliver, Msg}, State) ->
	State#state.deliver_to ! Msg,
	{noreply, State};

handle_info(Msg, State) ->
    io:format("[best_effort_bc_paper] received unknown message: ~p~n", [Msg]),
	{noreply, State}.

%%% MIL
handle_cast({message, _From, _To, Msg}, State) ->
	% received message from link layer -> forward to client
	State#state.deliver_to ! Msg,
	{noreply, State};
%%% LIM
handle_cast(Msg, State) ->
    io:format("[best_effort_bc_paper] received unhandled cast: ~p~n", [Msg]),
	{noreply, State}.

terminate(_Reason, _State) ->
	ok.