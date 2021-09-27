-module(reliable_broadcast).
%% best effort broadcast inspired by [Zeller2020](https://doi.org/10.1145/3406085.3409009)

-include("../observables/observer_events.hrl").
-behavior(gen_server).

-export([start_link/3, broadcast/2]).

% gen_server callbacks
-export([handle_call/3, handle_cast/2, handle_info/2, init/1, terminate/2]).

-record(state, {
	beb			:: bc_types:broadcast(), % best effort broadcast used for sending
	deliver_to	:: pid(), % receiver
	self		:: nonempty_string(), % name of local process
	max_mid	= 0 :: non_neg_integer(), % counter for ids
	local_delivered :: sets:set()
}).

-spec start_link(pid(), nonempty_string(), pid()) -> {'error', _} | {'ok', bc_types:broadcast()}.
start_link(LinkLayer, ProcessName, RespondTo) ->
	gen_server:start_link(?MODULE, [LinkLayer, ProcessName, RespondTo], []).

% broadcasts a message to all other nodes that we are connected to
-spec broadcast(bc_types:broadcast(), bc_types:message()) -> any().
broadcast(B, Msg) ->
	% erlang:display("Broadcasting: ~p~n", [Msg]),
	gen_server:call(B, {broadcast, Msg}).

init([LL, Name, R]) ->
	{ok, Beb} = best_effort_broadcast_paper:start_link(LL, Name, self()),
	{ok, #state{
		beb = Beb,
		deliver_to = R,
		self = unicode:characters_to_list([Name| "_rb"]),
		local_delivered = sets:new()
	}}.

-spec handle_call({'broadcast', bc_types:message()}, _, #state{beb::pid(), deliver_to::pid(), self::nonempty_string(), max_mid::non_neg_integer(), local_delivered::sets:set(_)}) -> {'reply', 'ok', #state{beb::pid(), deliver_to::pid(), self::nonempty_string(), max_mid::non_neg_integer(), local_delivered::sets:set(_)}}.
handle_call({broadcast, Msg}, _From, State) ->
	% deliver locally
	State#state.deliver_to ! {deliver, Msg},
	%%% OBS
	Event = {process, #obs_process_event{
		process = State#state.self,
		event_type = bc_delivered_event,
		event_content = #bc_delivered_event{
			message = Msg
		}
	}},
    gen_event:sync_notify({global,om}, Event),
	%%% SBO
	% calculate new MaxId
	Mids = lists:map(fun({_Pid, Mid}) -> Mid end, sets:to_list(State#state.local_delivered)),
	Mid = lists:max([0|Mids]) + 2,
	% broadcast to everyone
	best_effort_broadcast_paper:broadcast(State#state.beb, {State#state.self, Mid, Msg}),
	%%% OBS
    gen_event:sync_notify({global,om}, {process, #obs_process_event{
		process = State#state.self,
		event_type = bc_broadcast_event,
		event_content = #bc_broadcast_event{
			message = Msg
		}
	}}),
	%%% SBO
	% update state
	NewDelivered = sets:add_element({State#state.self, Mid}, State#state.local_delivered),
	{reply, ok, State#state{local_delivered = NewDelivered}}.

-spec handle_info({deliver, bc_types:message()}, _) -> {'noreply', _}.
handle_info({deliver, {Sender, Mid, Msg}}, State) ->
	case sets:is_element({Sender, Mid}, State#state.local_delivered) of
		true ->
			% we already delivered this, do nothing
			{noreply, State};
		false ->
			State#state.deliver_to ! {deliver, Msg},
			%%% OBS
			Event = {process, #obs_process_event{
				process = State#state.self,
				event_type = bc_delivered_event,
				event_content = #bc_delivered_event{
					message = Msg
				}
			}},
			gen_event:sync_notify({global,om}, Event),
			%%% SBO
			NewDelivered = sets:add_element({Sender, Mid}, State#state.local_delivered),
			% beb-broadcast again
			best_effort_broadcast_paper:broadcast(State#state.beb, {Sender,Mid,Msg}),
			%%% OBS
			gen_event:sync_notify({global,om}, {process, #obs_process_event{
				process = State#state.self,
				event_type = bc_broadcast_event,
				event_content = #bc_broadcast_event{
					message = Msg
				}
			}}),
			%%% SBO
			{noreply, State#state{local_delivered = NewDelivered}}
	end;
handle_info(Msg, State) ->
    io:format("[rb] received unknown message: ~p~n", [Msg]),
	{noreply, State}.

handle_cast(Msg, State) ->
    io:format("[rb] received unhandled cast: ~p~n", [Msg]),
	{noreply, State}.

terminate(_Reason, _State) ->
	ok.