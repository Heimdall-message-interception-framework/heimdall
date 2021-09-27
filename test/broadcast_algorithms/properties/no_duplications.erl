-module(no_duplications).
%%% PROPERTY: No message is delivered more than once.
-behaviour(gen_event).

-include("include/observer_events.hrl").
-include("src/broadcast_algorithms/bc_types.hrl").

-export([init/1, handle_call/2, handle_event/2, teminate/2]).

-record(state, {
    armed = false :: boolean(), % if set to true, we send updates about our state TODO: this needs to be implemented
    validity_p :: #{process_identifier() => boolean()},
    delivered_p :: #{process_identifier() => sets:set(bc_message())}
}).

%% property functions
-spec check_no_duplications(bc_message(), process_identifier(), #state{}) -> boolean().
check_no_duplications(Msg, Proc, State) -> 
    % check if message was already delivered
    IsDuplicate = sets:is_element(Msg, maps:get(Proc, State#state.delivered_p)),
    OldValidity = maps:get(Proc, State#state.validity_p, true),
    case IsDuplicate of
        true -> false; % duplicate detected, set validity to false
        false when OldValidity =:= true -> true; % no duplicate and validity was true
        _ -> false % no duplicate but validity was already false
    end.

init(_) ->
    {ok, #state{validity_p = maps:new(), delivered_p = maps:new()}}.

% handles delivered messages
-spec handle_event(_, #state{}) -> {'ok', #state{}}.
handle_event({process, #obs_process_event{process = Proc, event_type = bc_delivered_event, event_content = #bc_delivered_event{message = Msg}}}, State) ->
    % check if message was already delivered
    NewValidity = check_no_duplications(Msg, Proc, State),
    % add message to set of delivered messages
    NewDeliveredMessages = sets:add_element(Msg, maps:get(Proc, State#state.delivered_p, sets:new())),
    {ok, State#state{
        delivered_p = maps:put(Proc, NewDeliveredMessages, State#state.delivered_p),
        validity_p = maps:put(Proc, NewValidity, State#state.validity_p)}};
handle_event(Event, State) ->
    io:format("[no_duplications_prop] received unhandled event: ~p~n", [Event]),
    {ok, State}.

-spec handle_call(_, #state{}) -> {'ok', 'unhandled', #state{}} | {'ok', boolean() | #{process_identifier() => boolean()}, #state{}}.
handle_call(get_validity, State) ->
    {ok, State#state.validity_p, State};
handle_call({get_validity, Proc}, State) ->
    Reply = case maps:is_key(Proc, State#state.validity_p) of
                true -> maps:get(Proc, State#state.validity_p);
                _ -> io:format("[no_duplications_prop] unknown process key: ~p~n", [Proc]),
                    false
    end,
    {ok, Reply, State};
handle_call(Msg, State) ->
    io:format("[no_duplications_prop] received unhandled call: ~p~n", [Msg]),
    {ok, unhandled, State}.

-spec teminate(_, #state{}) -> 'ok'.
teminate(Reason, _State) ->
    io:format("[no_duplications_prop] Terminating. Reason: ~p~n", [Reason]).