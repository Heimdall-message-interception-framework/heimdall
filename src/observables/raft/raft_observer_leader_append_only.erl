-module(raft_observer_leader_append_only).
-behaviour(gen_event).

-include("observer_events.hrl").
-include("raft_observer_events.hrl").

-export([init/1, handle_call/2, handle_event/2]).

%% observer stores last stored idx for every process
%% - if not leader, checks whether idx increases if truncate is false (debug info if not)
%% - if leader, checks that idx increases and truncate is never false
%% assumption: a process knows when it is leader

-record(state, {
    property_satisfied = true :: boolean(),
    armed = true :: boolean(),
    update_target = undefined :: any(),
    history_of_events = queue:new() :: queue:queue(),
    process_to_idx_map = maps:new() :: maps:maps(),
    process_considers_itself_leader_map = maps:new() :: maps:maps()
%%    TO ADD: add more fields
    }).

%%    TO ADD: initialise added fields if necessary
init([UpdateTarget, PropSat, Armed]) ->
    {ok, #state{update_target = UpdateTarget, property_satisfied = PropSat, armed = Armed}};
init([UpdateTarget, PropSat]) ->
    init([UpdateTarget, PropSat, true]);
init([UpdateTarget]) ->
    init([UpdateTarget, true, false]);
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
            ra_log -> handle_log_request(Proc, EvContent, State1);
            ra_machine_state_update -> {true, State1};
            ra_machine_reply_write -> {true, State1};
            ra_machine_reply_read -> {true, State1};
            ra_machine_side_effects -> {true, State1};
            ra_server_state_variable -> handle_state_variable_event(Proc, EvContent, State);
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

handle_event(Event, State) ->
    erlang:display("unhandled raft event:"),
    erlang:display(Event),
    {ok, State}.

handle_call(get_result, #state{property_satisfied = PropSat} = State) ->
    {ok, PropSat, State};
handle_call(Msg, State) ->
    io:format("[raft_observer] received unhandled call: ~p~n", [Msg]),
    {ok, ok, State}.

add_to_history(State, GeneralEvent) ->
    NewHistory = queue:in(GeneralEvent, State#state.history_of_events),
    State#state{history_of_events = NewHistory}.

handle_log_request(Proc, #ra_log_obs_event{idx = Idx, trunc = Trunc},
    #state{process_to_idx_map = ProcIdxMap, process_considers_itself_leader_map = ProcLeaderMap} = State) ->
%%    check whether considered leader
    ConsidersItselfLeader = maps:get(Proc, ProcLeaderMap, false),
%%    get last Idx that was written
    LastIdx = maps:get(Proc, ProcIdxMap, -1),
    ProcIdxMap1 = maps:put(Proc, Idx, ProcIdxMap),
    State1 = State#state{process_to_idx_map = ProcIdxMap1},
    {StillSat, State2} =
        case ConsidersItselfLeader of
            true -> % check for leader
                {not ((Idx =< LastIdx) orelse Trunc), State1};
            false -> % check for follower and issue warning
                Conjunction = (Idx =< LastIdx) and (not Trunc),
                case Conjunction of
                    true -> erlang:display("Idx is smaller than or equal LastIdx but not listed as Truncate"),
                        erlang:display(["Idx", Idx, "LastIdx", LastIdx, "Trunc", Trunc]);
                    false -> ok
                end,
                {true, State1}
        end,
    {StillSat, State2}.

%% new leader_id for Proc
%% TODO: probably does not work as self() returns pid and leaders are names, debug with the erlang:display's
handle_state_variable_event(Proc, #ra_server_state_variable_obs_event{state_variable = leader_id, value = MaybeProcLeader},
    #state{process_considers_itself_leader_map = ProcLeaderMap} = State) ->
%%    erlang:display(["Proc", Proc]),
%%    erlang:display(["MaybeProcLeader", MaybeProcLeader]),
    ProcLeaderMap1 = maps:put(Proc, Proc == MaybeProcLeader, ProcLeaderMap),
    {true, State#state{process_considers_itself_leader_map = ProcLeaderMap1}};
handle_state_variable_event(_Proc, _EvContent, State) ->
    {true, State}.
