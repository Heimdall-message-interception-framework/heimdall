-module(raft_observer).
-behaviour(gen_event).

-include("observer_events.hrl").

-export([init/1, handle_call/2, handle_event/2]).

-record(state, {
    history_of_events :: queue:queue()
    }).

init(_) ->
    erlang:display("started raft_observer"),
    {ok, #state{history_of_events = queue:new()}}.

handle_event({process,
              #obs_process_event{process = _Proc, event_type = EvType, event_content = EvContent}} = ProcEvent,
              State) ->
%%    store event in history of events
    NewState = add_to_history(State, {process, ProcEvent}),
    case EvType of
        ra_log ->
            erlang:display("ra_log"),
            erlang:display(EvContent);
        ra_machine_state_update ->
            erlang:display("ra machine state update"),
            erlang:display(EvContent);
        ra_machine_reply_write ->
            erlang:display("ra machine reply write"),
            erlang:display(EvContent);
        ra_machine_reply_read ->
            erlang:display("ra machine reply read"),
            erlang:display(EvContent);
        ra_machine_side_effects ->
            erlang:display("ra machine side effects"),
            erlang:display(EvContent);
        _ -> erlang:display("unmatched event")
    end,
    {ok, NewState};
handle_event({sched, SchedEvent}, State) ->
%%    store event in history of events
    NewState = add_to_history(State, {sched, SchedEvent}),
    % TODO: do sth. concrete for observer here
    {ok, NewState};

handle_event(Event, State) ->
    erlang:display("unhandled raft event:"),
    erlang:display(Event),
    {ok, State}.

handle_call(Msg, State) ->
    io:format("[raft_observer] received unhandled call: ~p~n", [Msg]),
    {ok, ok, State}.

add_to_history(State, GeneralEvent) ->
    NewHistory = queue:in(GeneralEvent, State#state.history_of_events),
    State#state{history_of_events = NewHistory}.
