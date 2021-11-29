-module(raft_log_matching).
-behaviour(gen_event).

-include("observer_events.hrl").
-include("raft_observer_events.hrl").

-export([init/1, handle_call/2, handle_event/2]).

-record(state, {
    property_satisfied = true :: boolean(),
    armed = true :: boolean(),
    update_target = undefined :: any(),
    history_of_events = queue:new() :: queue:queue(),
    process_to_log_map = maps:new() :: maps:maps(any(), array:array())
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
            ra_server_state_variable -> {true, State1};
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

handle_log_request(Proc, #ra_log_obs_event{idx = Idx, term = Term, data = Data},
%%    TODO: update and unify with state predicate
    #state{process_to_log_map = ProcLogMap} = State) ->
%%    erlang:display(["Idx", Idx]),
    ArrayLog = case maps:get(Proc, ProcLogMap, undefined) of
        undefined ->  %
            array:set(10, true, array:new());
        SomeLog ->  % add new array to map
            SomeLog
    end,
    ArrayLog1 = array:set(Idx, {Term, Data}, ArrayLog),
    ProcLogMap1 = maps:put(Proc, ArrayLog1, ProcLogMap),
    State1 = State#state{process_to_log_map = ProcLogMap1},
    Result = check_that_logs_match(Proc, Idx, ProcLogMap1),
    {Result, State1}.


check_that_logs_match(Proc, Idx, ProcLogMap) ->
    Log = maps:get(Proc, ProcLogMap),
    IndivCheckFunction = fun(OtherProc, OtherLog, AccIn) ->
        case Proc == OtherProc of
            true -> AccIn;
            false ->
                case {array:get(Idx, Log), array:get(Idx, OtherLog)} of
                    {{Term, _Data1}, {Term, _Data2}} -> % agree
                        Result = check_two_logs_up_to_index(array:to_list(Log), array:to_list(OtherLog), Idx+3),
                        AccIn andalso Result;
                    _ -> AccIn
                end
        end
    end,
    Result = maps:fold(IndivCheckFunction, true, ProcLogMap),
    Result.

%% expects lists, not arrays
check_two_logs_up_to_index(Log1, Log2, Index) ->
    case Index of
        0 -> true;
        _ ->
            case {Log1, Log2} of
                {[X|Rest1], [X|Rest2]} -> check_two_logs_up_to_index(Rest1, Rest2, Index-1);
                _ -> false
            end
    end.
