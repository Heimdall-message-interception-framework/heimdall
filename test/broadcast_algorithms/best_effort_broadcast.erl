-module(best_effort_broadcast).

-behavior(gen_server).

-export([start_link/3, broadcast/2]).

% gen_server callbacks
-export([code_change/3, handle_call/3, handle_cast/2, handle_info/2, init/1, terminate/2]).

-record(state, {
	link_layer :: pid(),
	linked_node :: pid(),
	respond_to :: pid()
}).

start_link(LinkLayer, LinkedNode, RespondTo) ->
	gen_server:start_link(?MODULE, [LinkLayer, LinkedNode, RespondTo], []).

broadcast(B, Msg) ->
	erlang:display("started broadcast"),
	gen_server:call(B, {broadcast, Msg}).



init([LL, LN, R]) ->
	link_layer:register(LN, self()),
	{ok, #state{link_layer=LL, linked_node = LN, respond_to=R}}.

handle_call({broadcast, Msg}, _From, State) ->
	LL = State#state.link_layer,
%	AllNodes = gen_server:call(State#state.link_layer, {all_bc_pids}),
	AllNodes = gen_server:call(State#state.link_layer, {all_nodes}),
%	[gen_server:cast(LL, {bang, {self(), Node, Msg}}) || Node <- AllNodes],
	[gen_server:cast(LL, {send, Msg, Node}) || Node <- AllNodes],
	{reply, ok, State}.

handle_info({best_effort_broadcast_msg, Msg}, State) ->
	R = State#state.respond_to,
	R ! {deliver, Msg},
	{noreply, State}.

handle_cast(_Request, State) ->
	{noreply, State}.

terminate(_Reason, _State) ->
	ok.

code_change(_OldVsn, State, _Extra) ->
	{ok, State}.