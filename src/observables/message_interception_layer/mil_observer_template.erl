-module(mil_observer_template).
-behaviour(gen_event).

-include("observer_events.hrl").
-include("sched_event.hrl").

-export([init/1, handle_call/2, handle_event/2]).

-record(state, {
    property_satisfied = true :: boolean(),
    can_recover = false :: boolean(),
    armed = true :: boolean(),
    update_target = undefined :: any(),
    history_of_events = queue:new() :: queue:queue()
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
              #obs_process_event{process = _Proc, event_type = _EvType, event_content = _EvContent}} = ProcEvent,
              #state{property_satisfied = PropSat, armed = Armed, can_recover = CanRecover, update_target = UpdTarget} = State) ->
%%    store event in history of events
    State1 = add_to_history(State, {process, ProcEvent}),
%%    TO ADD: for process events
    NewPropSat = true, % ought to change
    update_prop_sat_and_notify(State, PropSat, NewPropSat, CanRecover, Armed, UpdTarget),
    {ok, State1};
%%
handle_event({sched,
    #sched_event{what = enable_to_crash, id = _Id, from = _Proc, to = _To, mod = _Module, func = _Fun, args = _Args} = SchedEvent},
    #state{property_satisfied = PropSat, armed = Armed, can_recover = CanRecover, update_target = UpdTarget} = State) ->
%%    store event in history of events
    State1 = add_to_history(State, {sched, SchedEvent}),
    % TO ADD: do sth. concrete here
    NewPropSat = true, % ought to change
    update_prop_sat_and_notify(State, PropSat, NewPropSat, CanRecover, Armed, UpdTarget),
    {ok, State1};
%%
handle_event({sched,
    #sched_event{what = enable_to, id = _TimerRef, from = _Proc, to = _To, mod = _Module, func = _Fun, args = _Args} = SchedEvent},
    #state{property_satisfied = PropSat, armed = Armed, can_recover = CanRecover, update_target = UpdTarget} = State) ->
%%    store event in history of events
    State1 = add_to_history(State, {sched, SchedEvent}),
    % TO ADD: do sth. concrete here
    NewPropSat = true, % ought to change
    update_prop_sat_and_notify(State, PropSat, NewPropSat, CanRecover, Armed, UpdTarget),
    {ok, State1};
%%
handle_event({sched,
    #sched_event{what = disable_to, id = _TimerRef, from = _Proc, to = _To} = SchedEvent},
    #state{property_satisfied = PropSat, armed = Armed, can_recover = CanRecover, update_target = UpdTarget} = State) ->
%%    store event in history of events
    State1 = add_to_history(State, {sched, SchedEvent}),
    % TO ADD: do sth. concrete here
    NewPropSat = true, % ought to change
    update_prop_sat_and_notify(State, PropSat, NewPropSat, CanRecover, Armed, UpdTarget),
    {ok, State1};
%%
handle_event({sched,
    #sched_event{what = fire_to, id = _TimerRef, from = _Proc, to = _To} = SchedEvent},
    #state{property_satisfied = PropSat, armed = Armed, can_recover = CanRecover, update_target = UpdTarget} = State) ->
%%    store event in history of events
    State1 = add_to_history(State, {sched, SchedEvent}),
    % TO ADD: do sth. concrete here
    NewPropSat = true, % ought to change
    update_prop_sat_and_notify(State, PropSat, NewPropSat, CanRecover, Armed, UpdTarget),
    {ok, State1};
%%
handle_event({sched,
    #sched_event{what = reg_node, name = _Name, class = _Class} = SchedEvent},
    #state{property_satisfied = PropSat, armed = Armed, can_recover = CanRecover, update_target = UpdTarget} = State) ->
%%    store event in history of events
    State1 = add_to_history(State, {sched, SchedEvent}),
    % TO ADD: do sth. concrete here
    NewPropSat = true, % ought to change
    update_prop_sat_and_notify(State, PropSat, NewPropSat, CanRecover, Armed, UpdTarget),
    {ok, State1};
%%
handle_event({sched,
    #sched_event{what = reg_clnt, name = _ClientName} = SchedEvent},
    #state{property_satisfied = PropSat, armed = Armed, can_recover = CanRecover, update_target = UpdTarget} = State) ->
%%    store event in history of events
    State1 = add_to_history(State, {sched, SchedEvent}),
    % TO ADD: do sth. concrete here
    NewPropSat = true, % ought to change
    update_prop_sat_and_notify(State, PropSat, NewPropSat, CanRecover, Armed, UpdTarget),
    {ok, State1};
%%
handle_event({sched,
    #sched_event{what = cmd_rcv_crsh, id = _Id, from = _From, to = _To, mod = _Module, func = _Fun, args = _Args} = SchedEvent},
    #state{property_satisfied = PropSat, armed = Armed, can_recover = CanRecover, update_target = UpdTarget} = State) ->
%%    store event in history of events
    State1 = add_to_history(State, {sched, SchedEvent}),
    % TO ADD: do sth. concrete here
    NewPropSat = true, % ought to change
    update_prop_sat_and_notify(State, PropSat, NewPropSat, CanRecover, Armed, UpdTarget),
    {ok, State1};
%%
handle_event({sched,
    #sched_event{what = cmd_rcv, id = _Id, from = _From, to = _To, mod = _Module, func = _Fun, args = _Args} = SchedEvent},
    #state{property_satisfied = PropSat, armed = Armed, can_recover = CanRecover, update_target = UpdTarget} = State) ->
%%    store event in history of events
    State1 = add_to_history(State, {sched, SchedEvent}),
    % TO ADD: do sth. concrete here
    NewPropSat = true, % ought to change
    update_prop_sat_and_notify(State, PropSat, NewPropSat, CanRecover, Armed, UpdTarget),
    {ok, State1};
%%
handle_event({sched,
    #sched_event{what = exec_msg_cmd, id = _Id, from = _From, to = _To, skipped = _Skipped, mod = _Module, func = _Fun, args = _Args} = SchedEvent},
    #state{property_satisfied = PropSat, armed = Armed, can_recover = CanRecover, update_target = UpdTarget} = State) ->
%%    store event in history of events
    State1 = add_to_history(State, {sched, SchedEvent}),
    % TO ADD: do sth. concrete here
    NewPropSat = true, % ought to change
    update_prop_sat_and_notify(State, PropSat, NewPropSat, CanRecover, Armed, UpdTarget),
    {ok, State1};
%%
handle_event({sched,
    #sched_event{what = duplicat, id = _Id, from = _From, to = _To, skipped = _Skipped, mod = _Module, func = _Fun, args = _Args} = SchedEvent},
    #state{property_satisfied = PropSat, armed = Armed, can_recover = CanRecover, update_target = UpdTarget} = State) ->
%%    store event in history of events
    State1 = add_to_history(State, {sched, SchedEvent}),
    % TO ADD: do sth. concrete here
    NewPropSat = true, % ought to change
    update_prop_sat_and_notify(State, PropSat, NewPropSat, CanRecover, Armed, UpdTarget),
    {ok, State1};
%%
handle_event({sched,
    #sched_event{what = snd_altr, id = _Id, from = _From, to = _To, skipped = _Skipped, mod = _Module, func = _Fun, args = _Args} = SchedEvent},
    #state{property_satisfied = PropSat, armed = Armed, can_recover = CanRecover, update_target = UpdTarget} = State) ->
%%    store event in history of events
    State1 = add_to_history(State, {sched, SchedEvent}),
    % TO ADD: do sth. concrete here
    NewPropSat = true, % ought to change
    update_prop_sat_and_notify(State, PropSat, NewPropSat, CanRecover, Armed, UpdTarget),
    {ok, State1};
%%
handle_event({sched,
    #sched_event{what = drop_msg, id = _Id, from = _From, to = _To, skipped = _Skipped, mod = _Module, func = _Fun, args = _Args} = SchedEvent},
    #state{property_satisfied = PropSat, armed = Armed, can_recover = CanRecover, update_target = UpdTarget} = State) ->
%%    store event in history of events
    State1 = add_to_history(State, {sched, SchedEvent}),
    % TO ADD: do sth. concrete here
    NewPropSat = true, % ought to change
    update_prop_sat_and_notify(State, PropSat, NewPropSat, CanRecover, Armed, UpdTarget),
    {ok, State1};
%%
handle_event({sched,
    #sched_event{what = trns_crs, name = _NodeName} = SchedEvent},
    #state{property_satisfied = PropSat, armed = Armed, can_recover = CanRecover, update_target = UpdTarget} = State) ->
%%    store event in history of events
    State1 = add_to_history(State, {sched, SchedEvent}),
    % TO ADD: do sth. concrete here
    NewPropSat = true, % ought to change
    update_prop_sat_and_notify(State, PropSat, NewPropSat, CanRecover, Armed, UpdTarget),
    {ok, State1};
%%
handle_event({sched,
    #sched_event{what = rejoin, name = _NodeName} = SchedEvent},
    #state{property_satisfied = PropSat, armed = Armed, can_recover = CanRecover, update_target = UpdTarget} = State) ->
%%    store event in history of events
    State1 = add_to_history(State, {sched, SchedEvent}),
    % TO ADD: do sth. concrete here
    NewPropSat = true, % ought to change
    update_prop_sat_and_notify(State, PropSat, NewPropSat, CanRecover, Armed, UpdTarget),
    {ok, State1};
%%
handle_event({sched,
    #sched_event{what = perm_crs, name = _NodeName} = SchedEvent},
    #state{property_satisfied = PropSat, armed = Armed, can_recover = CanRecover, update_target = UpdTarget} = State) ->
%%    store event in history of events
    State1 = add_to_history(State, {sched, SchedEvent}),
    % TO ADD: do sth. concrete here
    NewPropSat = true, % ought to change
    update_prop_sat_and_notify(State, PropSat, NewPropSat, CanRecover, Armed, UpdTarget),
    {ok, State1};
%%
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

update_prop_sat_and_notify(State, OldPropSat, NewPropSat, CanRecover, Armed, UpdateTarget) ->
    State1 = case OldPropSat == NewPropSat of % nothing changed
        true -> State;
        false ->
            % TODO: use CanRecover (also whether to change)
            State2 = State#state{property_satisfied = NewPropSat},
            % notify about change if armed
            case Armed of
                true -> UpdateTarget ! {property_sat_changed, NewPropSat};
                false -> ok
            end,
            State2
    end,
    State1.
