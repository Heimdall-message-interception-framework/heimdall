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
    % the process identifiers that we are listening to
    listen_to = sets:new() :: sets:set(process_identifier()),
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

% sets the vectorclock of a message
% only updates the VC of the message if it does not have a VC yet
-spec put_message(_, process_identifier(), #{bc_message() => vectorclock: vectorclock()}) -> #{bc_message() => vectorclock: vectorclock()}.
put_message(Msg, SenderVC, MsgVCs) ->
    case maps:is_key(Msg, MsgVCs) of
        false -> maps:put(Msg, SenderVC, MsgVCs);
        true -> MsgVCs % msg already has a VC, do not update state
    end.

% divide a list of compositional procnames like bc1_rco into a list of basenames + suffix
-spec proc_base_names([nonempty_string()]) -> {[nonempty_string()], string()}.
proc_base_names(ProcNames) ->
    GetBase = fun(Procname) -> case re:split(Procname, "_", [{return, list}]) of
        [] -> erlang:error("[~p] ERROR: Trying to determine base of invalid procname: ~p", [?MODULE, Procname]);
        [Base] -> {Base, ""};
        [Base | [Suffix]] -> {Base, Suffix}
    end end,
    WithSuffix = lists:map(GetBase, ProcNames),
    {_, Suffix} = hd(WithSuffix),
    {lists:map(fun({Base,_}) -> Base end, WithSuffix), Suffix}.

init([Config]) ->
    ListenTo = maps:get(listen_to, Config, []),
    {ok, #state{
        listen_to = sets:from_list(ListenTo),
        validity_p = maps:from_list(lists:map(fun(Proc) -> {Proc, true} end, ListenTo)),
        delivered_p = maps:from_list(lists:map(fun(Proc) -> {Proc, sets:new()} end, ListenTo))
    }}.

% handles delivered messages
-spec handle_event({sched, #sched_event{}}, #state{}) -> {'ok', #state{}}.
handle_event({process, #obs_process_event{process = Proc, event_type = bc_broadcast_event, event_content = #bc_broadcast_event{message = Msg}}}, State) ->
    HandleMessage = sets:is_element(Proc, State#state.listen_to),
    % only handle message if we listen to this process
    if HandleMessage ->
        % io:format("[~p] Received broadcast event: ~p, ~p", [?MODULE, Proc,Msg]),
        % calculate vectorclock of process
        OldVC = maps:get(Proc, State#state.vc_p, vectorclock:new()),
        NewVC = vectorclock:update_with(Proc, fun(I) -> I+1 end, 0, OldVC),
        MsgVCs = put_message(Msg, NewVC, State#state.vc_m),
        % io:format("[~p] PVCs: ~p, MVCs: ~p~n", [?MODULE, maps:put(Proc, NewVC, State#state.vc_p), MsgVCs]),

        % update vc of process and set vc of message
        {ok, State#state{
                vc_p = maps:put(Proc, NewVC, State#state.vc_p),
                vc_m = MsgVCs}};
    true -> {ok, State} end;
handle_event({process, #obs_process_event{process = Proc, event_type = bc_delivered_event, event_content = #bc_delivered_event{message = Msg}}}, State) ->
    HandleMessage = sets:is_element(Proc, State#state.listen_to),
    % only handle message if we listen to this process
    if HandleMessage ->
        % io:format("[~p] Received delivered event: ~p, ~p", [?MODULE, Proc,Msg]),
        % add message to set of delivered messages
        NewDeliveredMessages = sets:add_element(Msg, maps:get(Proc, State#state.delivered_p, sets:new())),
        % update vectorclock of process
        OldVC = maps:get(Proc, State#state.vc_p, vectorclock:new()),
        NewVC = vectorclock:update_with(Proc, fun(I) -> I+1 end, 0, OldVC),
        MsgVCs = put_message(Msg, NewVC, State#state.vc_m),
        % io:format("[~p] PVCs: ~p, MVCs: ~p~n", [?MODULE, maps:put(Proc, NewVC, State#state.vc_p), MsgVCs]),

        % check causal delivery property
        {ok, check_causal_delivery(Msg, Proc, 
            State#state{
                delivered_p = maps:put(Proc, NewDeliveredMessages, State#state.delivered_p),
                vc_p = maps:put(Proc, NewVC, State#state.vc_p),
                vc_m = MsgVCs})};
    true -> {ok, State} end;
handle_event({sched, #sched_event{what = exec_msg_cmd, from = From, to = To}}, State) ->
    % normalize names
    {_, Suffix} = proc_base_names(sets:to_list(State#state.listen_to)),
    % format to string if not already string
    From2 = case is_atom(From) of
        true -> atom_to_list(From);
        false -> From end,
    To2 = case is_atom(To) of
        true -> atom_to_list(To);
        false -> To end,
    FromStr = From2 ++ "_" ++ Suffix,
    ToStr = To2 ++ "_" ++ Suffix,
    % check if the name corresponds to the bc processes that we are listening to
    case sets:is_element(FromStr, State#state.listen_to) or 
            sets:is_element(To, State#state.listen_to) of
        true -> 
            % io:format("[~p] Received msg_event, from: ~p, to: ~p",
            %     [?MODULE, From, To]),
            % To receives a message from From -> update From's vectorclock
            SenderVC = maps:get(FromStr, State#state.vc_p, vectorclock:new()),
            ReceiverVC = maps:get(ToStr, State#state.vc_p, vectorclock:new()),
            NewVC = vectorclock:update_with(ToStr, fun(X) -> X+1 end, 0,
                vectorclock:max([SenderVC, ReceiverVC])),

            % io:format("[~p] SenderVC: ~p, ReceiverVC: ~p, NewReceiver: ~p", [?MODULE,SenderVC,ReceiverVC, NewVC]),

            {ok, State#state{
                vc_p = maps:put(ToStr, NewVC, State#state.vc_p)
            }};
        _ -> {ok, State} % ignore message
    end;
handle_event(_Event, State) ->
    % ignore unhandled events
    {ok, State}.

-spec handle_call(_, #state{}) -> {'ok', 'unhandled', #state{}} | {'ok', boolean() | #{process_identifier() => boolean()}, #state{}}.
handle_call(get_result, State) -> 
    {ok, State#state.validity_p, State};
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