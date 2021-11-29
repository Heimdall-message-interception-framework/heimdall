-module(statem_observer_template).
-behaviour(gen_event).

-include("observer_events.hrl").

-export([init/1, handle_call/2, handle_event/2]).

%% this one is designed for predicates, not properties
-record(state, {
%%    update_target = undefined :: any(),
    history_of_events = queue:new() :: queue:queue()
%%    TO ADD: add more fields for predicate state
    }).

%%    TO ADD: initialise added fields if necessary
init(_) ->
    {ok, #state{}}.

handle_event({process,
              #obs_process_event{process = _Proc, event_type = _EvType, event_content = _EvContent} = ProcEvent},
              #state{} = State) ->
%%    store event in history of events
    State1 = add_to_history(State, {process, ProcEvent}),
%%    TO ADD: for process events
    update_predicate_state(State, ProcEvent),
    {ok, State1};
%%
%% no handling of sched events here
%%
handle_event(Event, State) ->
    erlang:display("unhandled raft event:"),
    erlang:display(Event),
    {ok, State}.

handle_call(get_result, #state{} = State) ->
%%    TODO
    {ok, undefined, State};
handle_call(get_length_history, #state{history_of_events = HistoryOfEvents} = State) ->
    {ok, queue:len(HistoryOfEvents), State};
handle_call(Msg, State) ->
    io:format("[raft_observer] received unhandled call: ~p~n", [Msg]),
    {ok, ok, State}.

add_to_history(State, GeneralEvent) ->
    NewHistory = queue:in(GeneralEvent, State#state.history_of_events),
    State#state{history_of_events = NewHistory}.

update_predicate_state(State, #obs_process_event{process = _Proc, event_type = _EvType, event_content = _EvContent} = _ProcEvent) ->
%%  TODO
    State.

