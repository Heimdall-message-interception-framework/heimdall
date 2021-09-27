-module(causal_broadcast).

-include("../observables/observer_events.hrl").
%% best effort broadcast inspired by [Zeller2020](https://doi.org/10.1145/3406085.3409009)

-behavior(gen_server).

-export([start_link/3, broadcast/2]).
% gen_server callbacks
-export([handle_call/3, handle_cast/2, handle_info/2, init/1, terminate/2]).

-record(state,
        {rb :: bc_types:broadcast(), % best effort broadcast used for sending
         deliver_to :: pid(), % receiver
         self :: nonempty_string(), % name of local process
         pending :: sets:set(), % pending messages
         vc :: vectorclock:vectorclock()}). % local vectorclock

-spec start_link(pid(), atom(), pid()) -> {error, _} | {ok, bc_types:broadcast()}.
start_link(LinkLayer, ProcessName, RespondTo) ->
    gen_server:start_link(?MODULE, [LinkLayer, ProcessName, RespondTo], []).

% broadcasts a message to all other nodes that we are connected to
-spec broadcast(bc_types:broadcast(), bc_types:message()) -> any().
broadcast(B, Msg) ->
    % erlang:display("Broadcasting: ~p~n", [Msg]),
    gen_server:call(B, {rco_broadcast, Msg}).

init([LL, Name, R]) ->
    {ok, Rb} = reliable_broadcast:start_link(LL, Name, self()),
    {ok,
     #state{rb = Rb,
            deliver_to = R,
            self = unicode:characters_to_list([Name| "_rco"]),
            pending = sets:new(),
            vc = vectorclock:new()}}.

-spec handle_call({'rco_broadcast', bc_types:message()}, _, #state{deliver_to::pid(), self::nonempty_string(), pending::sets:set(_)}) -> {'reply', 'ok', #state{deliver_to::pid(), self::nonempty_string(), pending::sets:set(_)}}.
handle_call({rco_broadcast, Msg}, _From, State) ->
	% deliver locally
	State#state.deliver_to ! {deliver, Msg},
	%%% OBS
    gen_event:sync_notify({global,om}, {process, #obs_process_event{
		process = State#state.self,
		event_type = bc_delivered_event,
		event_content = #bc_delivered_event{
			message = Msg
		}
	}}),
	%%% SBO
	% broadcast to everyone
	reliable_broadcast:broadcast(State#state.rb, {State#state.self, State#state.vc, Msg}),
	%%% OBS
    gen_event:sync_notify({global,om}, {process, #obs_process_event{
		process = State#state.self,
		event_type = bc_broadcast_event,
		event_content = #bc_broadcast_event{
			message = Msg
		}
	}}),
	%%% SBO
	% increment vectorclock
    OldVal = vectorclock:get(State#state.self, State#state.vc),
    NewVC = vectorclock:set(State#state.self, OldVal+1, State#state.vc),
	{reply, ok, State#state{vc = NewVC}}.

-spec handle_info({deliver, bc_types:message()}, _) -> {noreply, _}.
handle_info({deliver, {P, VC, Msg}}, State) ->
    case P == State#state.self of
        true ->
            % we are the sender and already delivered this, do nothing
            {noreply, State};
        false ->
            Pending = sets:add_element({P, VC, Msg}, State#state.pending),
            {NewPending, NewVc} = deliver_pending(State, Pending, State#state.vc),
            {noreply, State#state{pending = NewPending, vc = NewVc}}
    end;
handle_info(Msg, State) ->
    io:format("[cb] received unknown message: ~p~n", [Msg]),
    {noreply, State}.

-spec deliver_pending(#state{deliver_to::pid(), self::nonempty_string(), pending::sets:set(_)}, sets:set(bc_types:message()), _) -> {sets:set(bc_types:message()), _}.
deliver_pending(State, Pending, Vc) ->
    CanDeliver = sets:filter(fun({_, VcQ, _}) -> vectorclock:le(VcQ, Vc) end, Pending),
    case sets:size(CanDeliver) of
        0 ->
            {Pending, Vc};
        _ ->
            NewPending = sets:subtract(Pending, CanDeliver),
            NewVc =
                sets:fold(fun({Q, _, M}, VcA) ->
                             State#state.deliver_to ! {deliver, M},
                            %%% OBS
                            gen_event:sync_notify({global,om}, {process, #obs_process_event{
                                process = State#state.self,
                                event_type = bc_delivered_event,
                                event_content = #bc_delivered_event{
                                    message = M
                                }
                            }}),
                            %%% SBO
                             % increment vector clock
                             OldVal = vectorclock:get(Q, VcA),
                             vectorclock:set(Q, OldVal+1,VcA)
                          end,
                          Vc,
                          CanDeliver),
            deliver_pending(State, NewPending, NewVc)
    end.

handle_cast(Msg, State) ->
    io:format("[cb] received unhandled cast: ~p~n", [Msg]),
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.
