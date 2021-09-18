-module(raft_observer).
-behaviour(gen_event).

-include("observer_events.hrl").

-export([init/1, handle_call/2, handle_event/2]).

-record(state, {history_of_events :: queue:queue()}).

init(_) ->
    {ok, #state{history_of_events = queue:new()}}.

handle_event({process, ProcEvent}, State) ->
%%    store event in history of events
    NewState = add_to_history(State, {process, ProcEvent}),
    % TODO: do sth. concrete for observer here
    {ok, NewState};
handle_event({process, #obs_process_event{process = Proc, event_type = EvType, event_content = EvContent}}, State) ->
    case EvType of
        ra_machine -> ok;
        ra_log -> ok;
        gen_mi_statem -> ok
    end,
    {ok, State};
handle_event({sched, SchedEvent}, State) ->
%%    store event in history of events
    NewState = add_to_history(State, {sched, SchedEvent}),
    % TODO: do sth. concrete for observer here
    {ok, NewState};
%%
handle_event(Event, State) ->
    io:format("[univ_observer] received unhandled event: ~p~n", [Event]),
    {ok, State}.

handle_call(Msg, State) ->
    io:format("[univ_observer] received unhandled call: ~p~n", [Msg]),
    {ok, ok, State}.

add_to_history(State, GeneralEvent) ->
    NewHistory = queue:in(State#state.history_of_events, GeneralEvent),
    State#state{history_of_events = NewHistory}.
