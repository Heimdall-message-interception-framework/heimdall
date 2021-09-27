-module(no_creation).
%%% PROPERTY: If a correct process j delivers a message, then m was broadcast to j by some process i.
-behaviour(gen_event).

-include("include/observer_events.hrl").
-include("src/broadcast_algorithms/bc_types.hrl").

-export([init/1, handle_call/2, handle_event/2, teminate/2]).

-record(state, {
    armed = false :: boolean(), % if set to true, we send updates about our state TODO: this needs to be implemented
    validity_p :: #{process_identifier() => boolean()},
    broadcast = sets:new() :: sets:set(bc_message()),
    delivered = sets:new() :: sets:set(bc_message())
}).

%% property functions
-spec check_no_creation(bc_message(), process_identifier(), #state{}) -> boolean().
check_no_creation(Msg, Proc, State) ->
    % check if delivered message was broadcast before
    WasBroadcast = sets:is_element(Msg, State#state.broadcast),
    OldValidity = maps:get(Proc, State#state.validity_p, true),
    case WasBroadcast of
        false -> false; % message was not broadcast before, set validity to false
        true when OldValidity =:= true -> true; % no creation and validity was true
        _ -> false % no creation but validity was already false
    end.

init(_) ->
    {ok, #state{validity_p = maps:new()}}.

% handles delivered messages
-spec handle_event(_, #state{}) -> {'ok', #state{}}.
handle_event({process, #obs_process_event{process = _Proc, event_type = bc_broadcast_event, event_content = #bc_broadcast_event{message = Msg}}}, State) ->
    % add message to set of broadcast messages
    NewBroadcastMessages = sets:add_element(Msg, State#state.broadcast),
    {ok, State#state{
        broadcast = NewBroadcastMessages}};
handle_event({process, #obs_process_event{process = Proc, event_type = bc_delivered_event, event_content = #bc_delivered_event{message = Msg}}}, State) ->
    % check if message was already delivered
    NewValidity = check_no_creation(Msg, Proc, State),
    % add message to set of delivered messages
    NewDeliveredMessages = sets:add_element(Msg, State#state.delivered),
    {ok, State#state{
        delivered = NewDeliveredMessages,
        validity_p = maps:put(Proc, NewValidity, State#state.validity_p)}};
handle_event(Event, State) ->
    io:format("[no_creation_prop] received unhandled event: ~p~n", [Event]),
    {ok, State}.

-spec handle_call(_, #state{}) -> {'ok', 'unhandled', #state{}} | {'ok', boolean() | #{process_identifier() => boolean()}, #state{}}.
handle_call(get_validity, State) ->
    {ok, State#state.validity_p, State};
handle_call({get_validity, Proc}, State) ->
    Reply = case maps:is_key(Proc, State#state.validity_p) of
                true -> maps:get(Proc, State#state.validity_p);
                _ -> io:format("[no_creation_prop] unknown process key: ~p~n", [Proc]),
                    false
    end,
    {ok, Reply, State};
handle_call(Msg, State) ->
    io:format("[no_creation_prop] received unhandled call: ~p~n", [Msg]),
    {ok, unhandled, State}.

-spec teminate(_, #state{}) -> 'ok'.
teminate(Reason, _State) ->
    io:format("[no_creation_prop] Terminating. Reason: ~p~n", [Reason]).