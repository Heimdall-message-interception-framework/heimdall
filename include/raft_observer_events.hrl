%%%-------------------------------------------------------------------
%%% @author fms
%%% @copyright (C) 2021, <COMPANY>
%%% @doc
%%%
%%% @end
%%% Created : 16. Sep 2021 15:44
%%%-------------------------------------------------------------------
-author("fms").

%% copy-pasted from raft
-record(ra_log_obs_event, {
  idx :: any(),
  term :: any(),
  trunc :: boolean(),
  data :: any()
}).

-record(ra_server_state_variable_obs_event, {
  state_variable :: atom(),  % one of current_term, leader_id, commit_index, last_applied, voted_for
  value :: any() % new value
}).

%% copy-pasted from ra-kv-store
-record(ra_machine_state_update_obs_event, {
  old_state :: any(),
  new_state :: any()
}).

-record(ra_machine_reply_write_obs_event, {
  index :: any(),
  term :: any()
}).

-record(ra_machine_reply_read_obs_event, {
  read :: any(),
  index :: any(),
  term :: any()
}).

-record(ra_machine_side_effects_obs_event, {
  side_effects :: any()
}).
