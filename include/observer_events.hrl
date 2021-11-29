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
}).

%% TODO: move to its own file (or merge others to this one)
%% process-local broadcast events
-record(bc_broadcast_event, { % newly broadcast message
  message :: any() % the message
}).
-record(bc_delivered_event, { % newly delivered message
  message :: any() % the message
}).

-record(statem_transition_event, {
  state :: {keep_state | repeat_state | next_state, any()},
  data :: {keep_data | repeat_data | next_data, any()}
}).

-record(statem_stop_event, {
  reason = undefined :: any() | undefined,
  replies = undefined :: any() | undefined,
  data = undefined :: any() | undefined
}).
