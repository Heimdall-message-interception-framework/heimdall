-module(causal_delivery).
%%% PROPERTY: No process p delivers a message m' unless p has already delivered every message m for
%%% which broadcast of m happens-before broadcast of m.
-behaviour(gen_event).

-include("observer_events.hrl").
-include("sched_event.hrl").
-include("src/broadcast_algorithms/bc_types.hrl").

-export([init/1, handle_call/2, handle_event/2, teminate/2]).

-record(state, {
    % if set to true, we send updates about our state TODO: this needs to be implemented
    armed = false :: boolean(),
    % keep a vectorclock per process
    vc_p = maps:new() :: #{process_identifier() => vectorclock:vectorclock()},
    % keep a vectorclock per message
    vc_m = maps:new() :: #{bc_message() => vectorclock: vectorclock()},
    validity_p = maps:new() :: #{process_identifier() => boolean()},
    delivered_p = maps:new() :: #{process_identifier() => sets:set(bc_message())}
}).

%% property functions
-spec check_causal_delivery(bc_message(), process_identifier(), #state{}) -> #state{}.
check_causal_delivery(Msg, Proc, State) ->
    % get the vc of the broadcast message
    MsgVC = maps:get(Msg, State#state.vc_m),

    % get all messages that happened before
    HBMessages = lists:filter(fun(M) ->
        ThisVC = maps:get(M, State#state.vc_m),
        vectorclock:lt(ThisVC, MsgVC) end,
        maps:keys(State#state.vc_m)),

    % check that they have already been delivered
    DeliveredMessages = maps:get(Proc, State#state.delivered_p, sets:new()),
    AllDelivered = lists:foldl(
        fun(M, Acc) -> Acc and sets:is_element(M, DeliveredMessages) end,
        true, HBMessages),
    State#state{
        validity_p = maps:put(Proc, AllDelivered, State#state.validity_p)
    }.

init(_) ->
    {ok, #state{}}.

% handles delivered messages
-spec handle_event(_, #state{}) -> {'ok', #state{}}.
handle_event({process, #obs_process_event{process = Proc, event_type = bc_broadcast_event, event_content = #bc_broadcast_event{message = Msg}}}, State) ->
    % io:format("Received broadcast event: ~p, ~p", [Proc,Msg]),
    % calculate vectorclock of process
    OldVC = maps:get(Proc, State#state.vc_p, vectorclock:new()),
    NewVC = vectorclock:update_with(Proc, fun(I) -> I+1 end, 0, OldVC),
    % io:format("PVCs: ~p, MVCs: ~p~n", [maps:put(Proc, NewVC, State#state.vc_p), maps:put(Msg, NewVC, State#state.vc_m)]),

    % update vc of process and set vc of message
    {ok, State#state{
            vc_p = maps:put(Proc, NewVC, State#state.vc_p),
            vc_m = maps:put(Msg, NewVC, State#state.vc_m)}};
handle_event({process, #obs_process_event{process = Proc, event_type = bc_delivered_event, event_content = #bc_delivered_event{message = Msg}}}, State) ->
    % io:format("Received delivered event: ~p, ~p", [Proc,Msg]),
    % add message to set of delivered messages
    NewDeliveredMessages = sets:add_element(Msg, maps:get(Proc, State#state.delivered_p, sets:new())),
    % update vectorclock of process
    OldVC = maps:get(Proc, State#state.vc_p, vectorclock:new()),
    NewVC = vectorclock:update_with(Proc, fun(I) -> I+1 end, 0, OldVC),
    % io:format("PVCs: ~p, MVCs: ~p~n", [maps:put(Proc, NewVC, State#state.vc_p), maps:put(Msg, NewVC, State#state.vc_m)]),

    % get or update vectorclock of the delivered message
    MsgVC = maps:get(Msg, State#state.vc_m, NewVC),
    
    % check causal delivery property
    {ok, check_causal_delivery(Msg, Proc, 
        State#state{
            delivered_p = maps:put(Proc, NewDeliveredMessages, State#state.delivered_p),
            vc_p = maps:put(Proc, NewVC, State#state.vc_p),
            vc_m = maps:put(Msg, MsgVC, State#state.vc_m)})};
handle_event({sched, #sched_event{what = exec_msg_cmd, from = From, to = To}}, State) ->
    % io:format("[causal_delivery_prop] Received msg_event, from: ~p, to: ~p",
    %     [From, To]),
    % To receives a message from From -> update From's vectorclock
    SenderVC = maps:get(From, State#state.vc_p, vectorclock:new()),
    ReceiverVC = maps:get(To, State#state.vc_p, vectorclock:new()),
    NewVC = vectorclock:update_with(To, fun(X) -> X+1 end, 0,
        vectorclock:max([SenderVC, ReceiverVC])),
    
    % io:format("[causal_delivery_prop] SenderVC: ~p, ReceiverVC: ~p, NewVC: ~p", [SenderVC,ReceiverVC, NewVC]),


    {ok, State#state{
        vc_p = maps:put(To, NewVC, State#state.vc_p)
    }};
handle_event(_Event, State) ->
    % ignore unhandled events
    {ok, State}.

-spec handle_call(_, #state{}) -> {'ok', 'unhandled', #state{}} | {'ok', boolean() | #{process_identifier() => boolean()}, #state{}}.
handle_call(get_validity, State) ->
    {ok, State#state.validity_p, State};
handle_call({get_validity, Proc}, State) ->
    Reply = case maps:is_key(Proc, State#state.validity_p) of
                true -> maps:get(Proc, State#state.validity_p);
                _ -> io:format("[causal_delivery_prop] unknown process key: ~p~n", [Proc]),
                    false
    end,
    {ok, Reply, State};
handle_call(Msg, State) ->
    io:format("[causal_delivery_prop] received unhandled call: ~p~n", [Msg]),
    {ok, unhandled, State}.

-spec teminate(_, #state{}) -> 'ok'.
teminate(Reason, _State) ->
    io:format("[causal_delivery_prop] Terminating. Reason: ~p~n", [Reason]).