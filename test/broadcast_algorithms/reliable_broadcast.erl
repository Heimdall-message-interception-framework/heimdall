-module(reliable_broadcast).
%% best effort broadcast inspired by [Zeller2020](https://doi.org/10.1145/3406085.3409009)

-behavior(gen_server).

-export([start_link/3, broadcast/2]).

% gen_server callbacks
-export([handle_call/3, handle_cast/2, handle_info/2, init/1, terminate/2]).

-record(state, {
	beb			:: pid(), % best effort broadcast used for sending
	deliver_to	:: pid(), % receiver
	self		:: atom(), % name of local process
	max_mid	= 0 :: non_neg_integer(), % counter for ids
	local_delivered :: sets:set()
}).

start_link(LinkLayer, ProcessName, RespondTo) ->
	gen_server:start_link(?MODULE, [LinkLayer, ProcessName, RespondTo], []).

% broadcasts a message to all other nodes that we are connected to
broadcast(B, Msg) ->
	% erlang:display("Broadcasting: ~p~n", [Msg]),
	gen_server:call(B, {broadcast, Msg}).

init([Beb, Name, R]) ->
	{ok, #state{
		beb = Beb,
		deliver_to = R,
		self = Name,
		local_delivered = sets:new()
	}}.

handle_call({broadcast, Msg}, _From, State) ->
	% deliver locally
	State#state.deliver_to ! {deliver, Msg},
	% calculate new MaxId
	Mid = lists:max(sets:to_list(State#state.local_delivered)) + 1,
	% broadcast to everyone
	best_effort_broadcast_paper:broadcast(State#state.beb, {State#state.self, Mid, Msg}),
	% update state
	NewDelivered = sets:add_element({State#state.self, Mid}, State#state.local_delivered),
	{reply, ok, State#state{local_delivered = NewDelivered}}.

handle_info({deliver, {Sender, Mid, Msg}}, State) ->
	case sets:is_element({Sender, Mid}, State#state.local_delivered) of
		true ->
			% we already delivered this, do nothing
			{noreply, State};
		false ->
			State#state.deliver_to ! {deliver, Msg},
			NewDelivered = sets:add_element({Sender, Mid}, State#state.local_delivered),
			% beb-broadcast again
			best_effort_broadcast_paper:broadcast(State#state.beb, {deliver,{Sender,Mid,Msg}}),
			{noreply, State#state{local_delivered = NewDelivered}}
	end;
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