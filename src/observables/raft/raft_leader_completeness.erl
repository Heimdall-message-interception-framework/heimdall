-module(raft_leader_completeness).
-behaviour(gen_event).

-include("observer_events.hrl").
-include("raft_observer_events.hrl").

-export([init/1, handle_call/2, handle_event/2]).

-record(state, {
    property_satisfied = true :: boolean(),
    armed = true :: boolean(),
    update_target = undefined :: any(),
    history_of_events = queue:new() :: queue:queue(),
    process_to_commit_idx_map = maps:new() :: maps:maps()
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
            ra_log -> handle_log_request(Proc, EvContent, State1);
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

handle_log_request(Proc, #ra_log_obs_event{idx = Idx},
    #state{process_to_commit_idx_map = ProcCommIdxMap} = State) ->
%%    get commit index
    CommitIdx = maps:get(Proc, ProcCommIdxMap, -1),
%%    check whether log writes before that
    StillSat = CommitIdx < Idx,
    {StillSat, State}.

%% new commit_index for Proc
handle_state_variable_event(Proc, #ra_server_state_variable_obs_event{state_variable = commit_index, value = CommitIndex},
    #state{process_to_commit_idx_map = ProcCommIdxMap} = State) ->
%%    get previous commit index
    PrevCommIndex = maps:get(Proc, ProcCommIdxMap, -1),
%%    check if commit index monotonically increases
    StillSat = PrevCommIndex =< CommitIndex,
%%    store new commit index
    ProcCommIdxMap1 = maps:put(Proc, CommitIndex, ProcCommIdxMap),
    {StillSat, State#state{process_to_commit_idx_map = ProcCommIdxMap1}};
handle_state_variable_event(_Proc, _EvContent, State) ->
    {true, State}.
