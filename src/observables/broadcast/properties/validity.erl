-module(validity).
-behaviour(gen_event).

-include("observer_events.hrl").
-include("bc_types.hrl").

-export([init/1, handle_call/2, handle_event/2, teminate/2]).

-record(state, {
    broadcast_p = maps:new() :: #{nonempty_string() => sets:set(bc_message())}, % broadcast events per process
    delivered_p = maps:new() :: #{nonempty_string() => sets:set(bc_message())}, % delivered events per process
    validity_p = maps: new() :: #{nonempty_string() => boolean()} % keeps track of valid processes
}).

%% property functions
% validity: every correct process that broadcasts a message, eventually delivers this message
-spec check_validity(#state{}) -> #state{}.
check_validity(State) ->
    CheckPerProcess = fun(Proc,Broadcast) ->
        % substract delivered messages from broadcast messages to check if there are messages that
        % still need to be delivered
        sets:is_empty(sets:subtract(Broadcast, maps:get(Proc, State#state.delivered_p, sets:new()))) end,
    Validity = maps:map(CheckPerProcess, State#state.broadcast_p),
    % io:format("[validity_prop]: validity is ~p~n", [Validity]),
    State#state{validity_p = Validity}.

check_properties(State) ->
    WithValidity = check_validity(State),
    WithValidity.

init(_) ->
    % io:format("[validity_prop] Started observer."),
    {ok, #state{}}.

% handles broadcast messages
handle_event({process, #obs_process_event{process = Proc, event_type = bc_broadcast_event, event_content = #bc_broadcast_event{message = Msg}}}, State) ->
    % add message to set of broadcasted messages
    NewBroadcastedMessages = sets:add_element(Msg, maps:get(Proc, State#state.broadcast_p, sets:new())), 
    % update broadcast_p in state
    NewState = State#state{broadcast_p = maps:put(Proc, NewBroadcastedMessages, State#state.broadcast_p)},
    PropertiesChecked = check_properties(NewState),
    % io:format("[validity_prop] process ~s broadcast message: ~p~n. Validity: ~p~n", [Proc, Msg, maps:get(Proc, PropertiesChecked#state.validity_p, true)]),
    {ok, PropertiesChecked};
% handles delivered messages
handle_event({process, #obs_process_event{process = Proc, event_type = bc_delivered_event, event_content = #bc_delivered_event{message = Msg}}}, State) ->
    % add message to set of delivered messages
    NewDeliveredMessages = sets:add_element(Msg, maps:get(Proc, State#state.delivered_p, sets:new())),
    % update delivered_p in state
    NewState = State#state{delivered_p = maps:put(Proc, NewDeliveredMessages, State#state.delivered_p)},
    PropertiesChecked = check_properties(NewState),
    % io:format("[validity_prop] process ~s delivered message: ~p. Validity: ~p~n", [Proc, Msg, maps:get(Proc, PropertiesChecked#state.validity_p, true)]),
    {ok, PropertiesChecked};
handle_event(_Event, State) ->
    % io:format("[validity_prop] received unhandled event: ~p~n", [_Event]),
    {ok, State}.

handle_call(get_result, State) -> 
    {ok, State#state.validity_p, State};
handle_call(Msg, State) ->
    io:format("[validity_prop] received unhandled call: ~p~n", [Msg]),
    {ok, ok, State}.

teminate(Reason, _State) ->
    io:format("[validity_prop] Terminating. Reason: ~p~n", [Reason]).