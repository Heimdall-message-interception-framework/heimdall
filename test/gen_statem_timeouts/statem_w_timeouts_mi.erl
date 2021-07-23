%%%-------------------------------------------------------------------
%%% @author fms
%%% @copyright (C) 2021, <COMPANY>
%%% @doc
%%%
%%% @end
%%% Created : 21. Jul 2021 09:32
%%%-------------------------------------------------------------------
-module(statem_w_timeouts_mi).
-author("fms").

%% TODO: first with normal gen_mi_statem
-behaviour(gen_mi_statem).

%% API
-export([start/0]).

%% gen_mi_statem callbacks
-export([init/1, format_status/2, handle_event/3, terminate/3,
  code_change/4, callback_mode/0]).
-export([initial/3, event_TO/3, state_TO/3, general_TO/3, another_state/3, final/3]).
-export([set_event_to/0, set_event_to/1, set_state_to/0, set_state_to/1,
  set_general_to/0, set_general_to/1, switch_state/0, keep_state/0, cancel_state_to/0, cancel_general_to/0]).

-define(SERVER, ?MODULE).

-record(statem_w_timeouts_state, {}).

%%%===================================================================
%%% API
%%%===================================================================

%% @doc Creates a gen_mi_statem process which calls Module:init/1 to
%% initialize. To ensure a synchronized start-up procedure, this
%% function does not return until Module:init/1 has returned.
start() ->
  gen_mi_statem:start_link({local, ?MODULE}, ?MODULE, [], []).

set_event_to() ->
  set_event_to(500).
set_event_to(Time) ->
  gen_mi_statem:cast(?MODULE, {set_event_to, Time}).
set_state_to() ->
  set_state_to(500).
set_state_to(Time) ->
  gen_mi_statem:cast(?MODULE, {set_state_to, Time}).
set_general_to() ->
  set_general_to(500).
set_general_to(Time) ->
  gen_mi_statem:cast(?MODULE, {set_general_to, Time}).
switch_state() ->
  gen_mi_statem:cast(?MODULE, {switch_state}).
keep_state() ->
  gen_mi_statem:cast(?MODULE, {keep_state}).
cancel_state_to() ->
  gen_mi_statem:cast(?MODULE, {cancel_state_to}).
cancel_general_to() ->
  gen_mi_statem:cast(?MODULE, {cancel_general_to}).

%%%===================================================================
%%% gen_mi_statem callbacks
%%%===================================================================

%% @private
%% @doc Whenever a gen_mi_statem is started using gen_mi_statem:start/[3,4] or
%% gen_mi_statem:start_link/[3,4], this function is called by the new
%% process to initialize.
init([]) ->
  {ok, initial, #statem_w_timeouts_state{}}.

%% @private
%% @doc This function is called by a gen_mi_statem when it needs to find out
%% the callback mode of the callback module.
callback_mode() ->
  state_functions.

%% @private
%% @doc Called (1) whenever sys:get_status/1,2 is called by gen_mi_statem or
%% (2) when gen_mi_statem terminates abnormally.
%% This callback is optional.
format_status(_Opt, [_PDict, _StateName, _State]) ->
  Status = some_term,
  Status.

%% @private
%% @doc There should be one instance of this function for each possible
%% state name.  If callback_mode is state_functions, one of these
%% functions is called when gen_mi_statem receives and event from
%% call/2, cast/2, or as a normal process message.
initial(cast, {set_event_to, Time}, State = #statem_w_timeouts_state{}) ->
  NextStateName = event_TO,
  observer_timeouts:add_new_event(initial__set_event_to),
  {next_state, NextStateName, State, {timeout, Time, event_timed_out}};
initial(cast, {set_state_to, Time}, State = #statem_w_timeouts_state{}) ->
  NextStateName = state_TO,
  observer_timeouts:add_new_event(initial__set_state_to),
  {next_state, NextStateName, State, {state_timeout, Time, state_timed_out}};
initial(cast, {set_general_to, Time}, State = #statem_w_timeouts_state{}) ->
  NextStateName = general_TO,
  observer_timeouts:add_new_event(initial__set_general_to),
  {next_state, NextStateName, State, {{timeout, general}, Time, general_timed_out}}.

event_TO(timeout, event_timed_out, State = #statem_w_timeouts_state{}) ->
  observer_timeouts:add_new_event(event_TO__event_timed_out),
  {next_state, final, State};
event_TO(EventType, EventContent, State) ->
  handle_event(EventType, EventContent, State).

state_TO(state_timeout, state_timed_out, State = #statem_w_timeouts_state{}) ->
  observer_timeouts:add_new_event(state_TO__state_timed_out),
  {next_state, final, State};
state_TO(cast, {set_state_to, infinity}, State = #statem_w_timeouts_state{}) ->
  observer_timeouts:add_new_event(state_TO__set_to_infinity),
  {next_state, initial, State, {state_timeout, infinity, state_timed_out}};
state_TO(cast, {set_state_to, Time}, State = #statem_w_timeouts_state{}) ->
  observer_timeouts:add_new_event(state_TO__set_to_Time),
  {keep_state, State, {state_timeout, Time, state_timed_out}};
state_TO(cast, {cancel_state_to}, State = #statem_w_timeouts_state{}) ->
  observer_timeouts:add_new_event(state_TO__cancelled),
  {next_state, initial, State, {state_timeout, cancel}};
state_TO(EventType, EventContent, State) ->
  handle_event(EventType, EventContent, State).

general_TO({timeout, general}, general_timed_out, State = #statem_w_timeouts_state{}) ->
  observer_timeouts:add_new_event(general_TO__general_timed_out),
  {next_state, final, State};
general_TO(cast, {set_general_to, infinity}, State = #statem_w_timeouts_state{}) ->
  observer_timeouts:add_new_event(general_TO__set_to_inf),
  {next_state, initial, State, {{timeout, general}, infinity, general_timed_out}};
general_TO(cast, {set_general_to, Time}, State = #statem_w_timeouts_state{}) ->
  observer_timeouts:add_new_event(general_TO__set_to_Time),
  {keep_state, State, {{timeout, general}, Time, general_timed_out}};
general_TO(cast, {cancel_general_to}, State = #statem_w_timeouts_state{}) ->
  observer_timeouts:add_new_event(general_TO__cancelled),
  {next_state, initial, State, {{timeout, general}, cancel}};
general_TO(EventType, EventContent, State) ->
  handle_event(EventType, EventContent, State).

another_state(timeout, event_timed_out, _State = #statem_w_timeouts_state{}) ->
  observer_timeouts:add_new_event(another_state__event_timed_out),
%%  erlang:display("event timed out in another state; should not happen"),
  {keep_state_and_data};
another_state(state_timeout, state_timed_out, _State = #statem_w_timeouts_state{}) ->
  observer_timeouts:add_new_event(another_state__state_timed_out),
%%  erlang:display("state timed out in another state; shoud not happen"),
  {keep_state_and_data};
another_state({timeout, general}, general_timed_out, State = #statem_w_timeouts_state{}) ->
  observer_timeouts:add_new_event(another_state__general_timed_out),
%%  erlang:display("general timed out in another state"),
  {next_state, final, State};
another_state(EventType, EventContent, State) ->
  erlang:display("any other event should not happen"),
  handle_event(EventType, EventContent, State).

final(EventType, EventContent, State) ->
  handle_event(EventType, EventContent, State).

%% @private
%% @doc If callback_mode is handle_event_function, then whenever a
%% gen_mi_statem receives an event from call/2, cast/2, or as a normal
%% process message, this function is called.
handle_event(cast, {switch_state}, State = #statem_w_timeouts_state{}) ->
  observer_timeouts:add_new_event(any_state__switch_state),
  NextStateName = another_state,
  {next_state, NextStateName, State};
handle_event(cast, {keep_state}, State = #statem_w_timeouts_state{}) ->
%%  this one should cancel event_timeout but not state_timeout
  observer_timeouts:add_new_event(any_state__keep_state),
  {keep_state, State};
handle_event(_EventType, _EventContent, _State) ->
  observer_timeouts:add_new_event(any_state__unhandled_event),
  erlang:display("unhandled event"),
  {keep_state_and_data}.

%% @private
%% @doc This function is called by a gen_mi_statem when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any
%% necessary cleaning up. When it returns, the gen_mi_statem terminates with
%% Reason. The return value is ignored.
terminate(_Reason, _StateName, _State = #statem_w_timeouts_state{}) ->
  ok.

%% @private
%% @doc Convert process state when code is changed
code_change(_OldVsn, StateName, State = #statem_w_timeouts_state{}, _Extra) ->
  {ok, StateName, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================
