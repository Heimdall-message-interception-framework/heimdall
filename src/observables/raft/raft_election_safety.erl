-module(raft_election_safety).
-behaviour(gen_event).

-include("observer_events.hrl").
-include("raft_observer_events.hrl").

-export([init/1, handle_call/2, handle_event/2]).

-record(state, {
    property_satisfied = true :: boolean(),
    armed = true :: boolean(),
    update_target = undefined :: any(),
    history_of_events = queue:new() :: queue:queue(),
    term_to_leader_map = maps:new() :: maps:maps(),
    process_to_term_map = maps:new() :: maps:maps(),
    process_to_leader_map = maps:new() :: maps:maps()
%%    TO ADD: add more fields
    }).

%%    TO ADD: initialise added fields if necessary
init([UpdateTarget, PropSat, Armed]) ->
    {ok, #state{update_target= UpdateTarget, property_satisfied= PropSat, armed=Armed}};
init([UpdateTarget, PropSat]) ->
    init([UpdateTarget, PropSat, true]);
init([UpdateTarget]) ->
    init([UpdateTarget, true]);
init(_) ->
    init([undefined, true]).

handle_event({process,
              #obs_process_event{process = Proc, event_type = EvType, event_content = EvContent}} = ProcEvent,
              #state{property_satisfied = PropSat, armed = _Armed, update_target = _UpdTarget} = State) ->
%%    store event in history of events
    State1 = add_to_history(State, {process, ProcEvent}),
    {NewPropSat, State2} =
        case EvType of
                             % TO ADD: do sth. for concrete cases
            ra_log -> {true, State1};
            ra_machine_state_update -> {true, State1};
            ra_machine_reply_write -> {true, State1};
            ra_machine_reply_read -> {true, State1};
            ra_machine_side_effects -> {true, State1};
            ra_server_state_variable -> handle_state_variable_event(Proc, EvContent, State);
            statem_transition_event -> {true, State1};
            statem_stop_event -> {true, State1};
            _ -> erlang:display("unmatched event")
        end,
    case PropSat of
        false ->
            {ok, State2};
        true ->
            State3 = State2#state{property_satisfied = NewPropSat},
            {ok, State3}
    end;
handle_event({sched, SchedEvent}, State) ->
%%    store event in history of events
    NewState = add_to_history(State, {sched, SchedEvent}),
    % TO ADD: do sth. concrete here
    {ok, NewState};

handle_event(_Event, State) ->
%%    erlang:display("unhandled raft event:"),
%%    erlang:display(Event),
    {ok, State}.

handle_call(get_result, #state{property_satisfied = PropSat} = State) ->
    {ok, PropSat, State};
handle_call(Msg, State) ->
    io:format("[raft_observer] received unhandled call: ~p~n", [Msg]),
    {ok, ok, State}.

add_to_history(State, GeneralEvent) ->
    NewHistory = queue:in(GeneralEvent, State#state.history_of_events),
    State#state{history_of_events = NewHistory}.


%% internal functions
%% TODO: issue with synchronous submission of events,
%% will need to collect a list of changes after which the condition is checked

%% in general, leader_id is turned to undefined if the term is increased and then set again
%% however, this is not the case when a candidate adapts its term and leader I think
%% TODO: investigate this further

%% new current_term for Proc
handle_state_variable_event(Proc, #ra_server_state_variable_obs_event{state_variable = current_term, value = CurrentTerm},
        #state{process_to_term_map = ProcTermMap, process_to_leader_map = ProcLeaderMap,
            term_to_leader_map = TermLeaderMap} = State) ->
%%    store new term for Proc
    ProcTermMap1 = maps:put(Proc, CurrentTerm, ProcTermMap),
    State1 = State#state{process_to_term_map = ProcTermMap1},
%%    get leader for Proc
    MaybeProcLeader = maps:get(Proc, ProcLeaderMap, undefined),
%%    get leader for CurrentTerm (overall)
    MaybeOverallLeader = maps:get(CurrentTerm, TermLeaderMap, undefined),
    compare_procleader_and_overall_leader(MaybeProcLeader, MaybeOverallLeader, CurrentTerm, State1, TermLeaderMap);

%% new leader_id for Proc
handle_state_variable_event(Proc, #ra_server_state_variable_obs_event{state_variable = leader_id, value = MaybeProcLeader},
        #state{process_to_leader_map = ProcLeaderMap, process_to_term_map = ProcTermMap, term_to_leader_map = TermLeaderMap} = State) ->
%%    store new leader for proc
    ProcLeaderMap1 = maps:put(Proc, MaybeProcLeader, ProcLeaderMap),
    State1 = State#state{process_to_leader_map = ProcLeaderMap1},
    ProcCurrentTerm = maps:get(Proc, ProcTermMap, 0),
    MaybeOverallLeader = maps:get(ProcCurrentTerm, TermLeaderMap, undefined),
    compare_procleader_and_overall_leader(MaybeProcLeader, MaybeOverallLeader, ProcCurrentTerm, State1, TermLeaderMap);
handle_state_variable_event(_Proc, _EvContent, State) ->
    {true, State}.

compare_procleader_and_overall_leader(MaybeProcLeader, MaybeOverallLeader, CurrentTerm, State, TermLeaderMap) ->
    case {MaybeProcLeader, MaybeOverallLeader} of
        {undefined, _} -> % if ProcLeader is not known, property is satisfied
            {true, State};
        {ProcLeader, undefined} -> % overall leader is unknown, store it
            TermLeaderMap1 = maps:put(CurrentTerm, ProcLeader, TermLeaderMap),
            {true, State#state{term_to_leader_map = TermLeaderMap1}};
        {ProcLeader, OverallLeader} -> % overall leader is unknown, check against it
            LeadersAgree = ProcLeader == OverallLeader,
            {LeadersAgree, State}
    end.
