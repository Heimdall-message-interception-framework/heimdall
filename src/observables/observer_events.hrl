%%%-------------------------------------------------------------------
%%% @author fms
%%% @copyright (C) 2021, <COMPANY>
%%% @doc
%%%
%%% @end
%%% Created : 16. Sep 2021 15:44
%%%-------------------------------------------------------------------
-author("fms").

%% Attempt to have types for observer events
%% explicit process event with pid or name to easily have observers on certain processes

-export_type([obs_event/0]).

-type obs_event() :: {process, any()} |
                     {sched, any()}.
%% TODO: solve how to use record as types...
%%-type obs_sched_event() :: sched_event(). % wrong type, also record here

-type process_identifier() :: pid() | atom() | nonempty_string().

-record(obs_process_event, {
  process :: process_identifier(),
  event_type :: atom(),
  event_content :: any()
%%  the idea is to pattern-match on event_type (e.g. ra_log) and then have the same shape in event_content
%%  for raft currently:
%%    ra_log - {ra_log, {{pid, PId}, {idx, Idx}, {term, Term}, {trunc, Trunc}, {data, Data0}}}
%%    ra_machine // need to distinguish to pattern-match
%%               - {ra_machine, {{pid, self()}, {state_update, State, NewState}}}
%%                 {ra_machine, {{pid, self()}, {reply, {{index, Index}, {term, Term}}}}}
%%                 {ra_machine, {{pid, self()}, {side_effects, SideEffects}}}
%%    gen_mi_statem - a lot on different state and data etc //currently not used anymore
}).

-record(ra_log_event, {

}).

%% process-local broadcast events
-record(bc_broadcast_event, { % newly broadcast message
  message :: any() % the message
}).
-record(bc_delivered_event, { % newly delivered message
  message :: any() % the message
}).