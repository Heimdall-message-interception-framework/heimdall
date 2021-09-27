-module(broadcast_observer).
-behaviour(gen_event).

-include("observer_events.hrl").

-export([init/1, handle_call/2, handle_event/2, teminate/2]).

-record(state, {
    history_of_events :: queue:queue(),
    broadcast_p = maps:new() :: #{nonempty_string() => sets:set(bc_types:message())}, % broadcast events per process
    delivered_p = maps:new() :: #{nonempty_string() => sets:set(bc_types:message())}, % delivered events per process
    validity_p = maps: new() :: #{nonempty_string() => boolean()} % keeps track of valid processes
}).

%% property functions
% validity: every correct process that broadcasts a message, eventually delivers this message
-spec check_validity(#state{history_of_events::queue:queue(_), broadcast_p::#{nonempty_string()=>sets:set(_)}, delivered_p::#{nonempty_string()=>sets:set(_)}, validity_p::#{nonempty_string()=>boolean()}}) -> #state{history_of_events::queue:queue(_), broadcast_p::#{nonempty_string()=>sets:set(_)}, delivered_p::#{nonempty_string()=>sets:set(_)}, validity_p::#{nonempty_string()=>boolean()}}.
check_validity(State) ->
    CheckPerProcess = fun(Proc,Broadcast) ->
        % substract delivered messages from broadcast messages to check if there are messages that
        % still need to be delivered
        sets:is_empty(sets:subtract(Broadcast, maps:get(Proc, State#state.delivered_p))) end,
    Validity = maps:map(CheckPerProcess, State#state.broadcast_p),
    io:format("[broadcast_observer]: validity is ~p~n", [Validity]),
    State#state{validity_p = Validity}.

check_properties(State) ->
    WithValidity = check_validity(State),
    WithValidity.

init(_) ->
    io:format("[bc_observer] Started observer."),
    {ok, #state{history_of_events = queue:new()}}.

% handles broadcast messages
handle_event({process, #obs_process_event{process = Proc, event_type = bc_broadcast_event, event_content = #bc_broadcast_event{message = Msg}}}, State) ->
    % add message to set of broadcasted messages
    NewBroadcastedMessages = sets:add_element(Msg, maps:get(Proc, State#state.broadcast_p, sets:new())), 
    % update broadcast_p in state
    NewState = State#state{broadcast_p = maps:put(Proc, NewBroadcastedMessages, State#state.broadcast_p)},
    PropertiesChecked = check_properties(NewState),
    io:format("[broadcast_observer] process ~s broadcast message: ~p~n. Validity: ~p~n", [Proc, Msg, maps:get(Proc, PropertiesChecked#state.validity_p, true)]),
    {ok, PropertiesChecked};
% handles delivered messages
handle_event({process, #obs_process_event{process = Proc, event_type = bc_delivered_event, event_content = #bc_delivered_event{message = Msg}}}, State) ->
    % add message to set of delivered messages
    NewDeliveredMessages = sets:add_element(Msg, maps:get(Proc, State#state.broadcast_p, sets:new())),
    % update delivered_p in state
    NewState = State#state{delivered_p = maps:put(Proc, NewDeliveredMessages, State#state.delivered_p)},
    PropertiesChecked = check_properties(NewState),
    io:format("[broadcast_observer] process ~s delivered message: ~p. Validity: ~p~n", [Proc, Msg, maps:get(Proc, PropertiesChecked#state.validity_p, true)]),
    {ok, PropertiesChecked};
handle_event({sched, SchedEvent}, State) ->
%%    store event in history of events
    NewState = add_to_history(State, {sched, SchedEvent}),
    % TODO: do sth. concrete for observer here
    {ok, NewState};
handle_event(Event, State) ->
    io:format("[broadcast_observer] received unhandled event: ~p~n", [Event]),
    {ok, State}.

handle_call(Msg, State) ->
    io:format("[broadcast_observer] received unhandled call: ~p~n", [Msg]),
    {ok, State}.

-spec add_to_history(#state{history_of_events::queue:queue(_)}, {'process', _} | {'sched', _}) -> #state{history_of_events::queue:queue(_)}.
add_to_history(State, GeneralEvent) ->
    NewHistory = queue:in(GeneralEvent, State#state.history_of_events),
    State#state{history_of_events = NewHistory}.

teminate(Reason, _State) ->
    io:format("[broadcast_observer] Terminating. Reason: ~p~n", [Reason]).