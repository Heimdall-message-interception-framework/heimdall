-module(agreement).
%%% PROPERTY: If a message m is delivered by some correct process i, then m is eventually delivered by every correct process j.
-behaviour(gen_event).

-include("observer_events.hrl").
-include("bc_types.hrl").

-export([init/1, handle_call/2, handle_event/2, teminate/2]).

% errors capture potential problems where a message was delivered by some
% processes but not others
-record(error, {
    message :: bc_message(),
    delivered_by :: list(process_identifier()),
    not_delivered_by :: list(process_identifier())
}).

-record(state, {
    % if set to true, we send updates about our state TODO: this needs to be implemented
    armed = false :: boolean(),
    listen_to = sets:new() :: sets:set(process_identifier()),
    validity_p = maps:new() :: #{process_identifier() => boolean()},
    errors = [] :: list(#error{}),
    delivered_p = maps:new() :: #{process_identifier() => sets:set(bc_message())}
}).

%% property functions
-spec check_agreement(bc_message(), process_identifier(), #state{}) -> #state{}.
check_agreement(Msg, Proc, State) ->
    % check if message was already delivered by every other process
    AllProcesses = maps:keys(State#state.delivered_p),
    NotDeliveredBy = lists:filter(
        fun (P) -> not sets:is_element(Msg, maps:get(P, State#state.delivered_p, sets:new())) end,
        AllProcesses),
    NewErrors = update_errors(Msg, AllProcesses, NotDeliveredBy, State#state.errors),

    case NotDeliveredBy of
        % this message was delivered by everyone and there are no other errors,
        % set all processes to valid
        [] when NewErrors =:= [] -> State#state{
            validity_p = maps:from_list(lists:map(fun (P) -> {P, true} end, AllProcesses)),
            errors = NewErrors
        };
        % this message was delivered correctly but there are other errors,
        % do not touch the validity
        [] when NewErrors =/= [] -> State#state {
            errors = NewErrors
        };
        % this process delivered something that is not yet delivered by all other processes,
        % set all other processes to invalid
        _ -> 
            OtherProcs = [P || P <- AllProcesses, P =/= Proc],
            State#state{
                validity_p = lists:foldl(fun(P, Acc) -> maps:put(P, false, Acc) end,
                    State#state.validity_p, OtherProcs), 
                errors = NewErrors
        }
    end.
    
-spec update_errors(bc_message(), [process_identifier()], [process_identifier()], [#error{}]) -> [#error{}].
update_errors(Msg, AllProcesses, NotDeliveredBy, OldErrs) ->
    OtherErrors = lists:filter(fun (Err) -> Err#error.message =/= Msg end, OldErrs),
    case NotDeliveredBy of
        % every Process delivered the message, remove it from the errors
        [] -> OtherErrors;
        % otherwise add an updated error
        _ ->
            DeliveredBy = lists:filter(
                fun (P) -> not lists:member(P, NotDeliveredBy) end,
                AllProcesses), 
            OtherErrors ++ [#error{
                message = Msg,
                not_delivered_by = NotDeliveredBy,
                delivered_by = DeliveredBy
            }]
        end.

init([Config]) ->
    ListenTo = maps:get(listen_to, Config, []),
    {ok, #state{
        listen_to = sets:from_list(ListenTo),
        validity_p = maps:from_list(lists:map(fun(Proc) -> {Proc, true} end, ListenTo)),
        delivered_p = maps:from_list(lists:map(fun(Proc) -> {Proc, sets:new()} end, ListenTo))
    }}.

% handles delivered messages
-spec handle_event(_, #state{}) -> {'ok', #state{}}.
handle_event({process, #obs_process_event{process = Proc, event_type = bc_delivered_event, event_content = #bc_delivered_event{message = Msg}}}, State) -> 
    HandleMessage = sets:is_element(Proc, State#state.listen_to),
    
    % only handle message if we listen to this process
    if HandleMessage ->
        % add message to set of delivered messages
        NewDeliveredMessages = sets:add_element(Msg, maps:get(Proc, State#state.delivered_p, sets:new())),

        % check agreement property
        {ok, check_agreement(Msg, Proc, 
            State#state{delivered_p = maps:put(Proc, NewDeliveredMessages, State#state.delivered_p)})}; 
    true -> {ok,State}
end;
handle_event(_Event, State) ->
    % io:format("[agreement_prop] received unhandled event: ~p~n", [Event]),
    {ok, State}.

-spec handle_call(_, #state{}) -> {'ok', 'unhandled', #state{}} | {'ok', boolean() | #{process_identifier() => boolean()}, #state{}}.
handle_call(get_result, State) -> 
    {ok, State#state.validity_p, State};
handle_call(get_validity, State) ->
    {ok, State#state.validity_p, State};
handle_call({get_validity, Proc}, State) ->
    Reply = case maps:is_key(Proc, State#state.validity_p) of
                true -> maps:get(Proc, State#state.validity_p);
                _ -> io:format("[agreement_prop] unknown process key: ~p~n", [Proc]),
                    false
    end,
    {ok, Reply, State};
handle_call(get_errors, State) ->
    PrintErr = fun (Err) ->
        io:format("[agreement_prop] ERROR: Message ~p was delivered by processes ~p but not by ~p.",
        [Err#error.message, Err#error.delivered_by, Err#error.not_delivered_by])
    end,
    lists:foreach(PrintErr, State#state.errors),
    {ok, State#state.errors, State};
handle_call(Msg, State) ->
    io:format("[agreement_prop] received unhandled call: ~p~n", [Msg]),
    {ok, unhandled, State}.

-spec teminate(_, #state{}) -> 'ok'.
teminate(Reason, _State) ->
    io:format("[agreement_prop] Terminating. Reason: ~p~n", [Reason]).