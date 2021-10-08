%%%-------------------------------------------------------------------
%%% @author fms
%%% @copyright (C) 2021, <COMPANY>
%%% @doc
%%%
%%% @end
%%% Created : 04. Oct 2021 15:08
%%%-------------------------------------------------------------------
-module(raft_observer_tests_SUITE).
-author("fms").

-include("raft_observer_events.hrl").
-include("observer_events.hrl").

-define(ObserverManager, {global, om}).

%% API
-export([all/0, init_per_suite/1]).
-export([leader_append_only_good_1/1, leader_append_only_bad_1/1, end_per_suite/1, election_safety_good_1/1, election_safety_bad_1/1, leader_completeness_good_1/1, leader_completeness_bad_1/1, leader_completeness_bad_2/1, state_machine_safety_good_1/1, state_machine_safety_bad_1/1, state_machine_safety_bad_2/1, log_matching_good_1/1, log_matching_bad_1/1]).

all() -> [
  election_safety_good_1,
  election_safety_bad_1,
  leader_append_only_good_1,
  leader_append_only_bad_1,
  leader_completeness_good_1,
  leader_completeness_bad_1,
  leader_completeness_bad_2,
  state_machine_safety_good_1,
  state_machine_safety_bad_1,
  state_machine_safety_bad_2,
  log_matching_good_1,
  log_matching_bad_1
].

init_per_suite(Config) ->
  logger:set_primary_config(level, info),
  % create observer manager
  {ok, _} = gen_event:start(?ObserverManager),
  Config.

end_per_suite(Config) ->
  Config.

election_safety_good_1(_Config) ->
  gen_event:add_handler(?ObserverManager, raft_election_safety, [self(), true, true]), % propsat, armed
  submit_ra_server_state_variable_event(proc1, current_term, 0),
  submit_ra_server_state_variable_event(proc2, current_term, 0),
  submit_ra_server_state_variable_event(proc1, leader_id, proc1),
  submit_ra_server_state_variable_event(proc2, leader_id, proc1),
  submit_ra_server_state_variable_event(proc1, leader_id, undefined), % needed for both as we also check if current term changes
  submit_ra_server_state_variable_event(proc2, leader_id, undefined), % maybe adapt this in the future
  submit_ra_server_state_variable_event(proc2, current_term, 1),
  submit_ra_server_state_variable_event(proc1, current_term, 1),
  submit_ra_server_state_variable_event(proc2, leader_id, proc2),
  submit_ra_server_state_variable_event(proc1, leader_id, proc2),
  PropSat = gen_event:call(?ObserverManager, raft_election_safety, get_result),
  gen_event:delete_handler(?ObserverManager, raft_election_safety, []),
  check_result(?FUNCTION_NAME, PropSat, true).

election_safety_bad_1(_Config) ->
  gen_event:add_handler(?ObserverManager, raft_election_safety, [self(), true, true]), % propsat, armed
  submit_ra_server_state_variable_event(proc1, current_term, 0),
  submit_ra_server_state_variable_event(proc2, current_term, 0),
  submit_ra_server_state_variable_event(proc1, leader_id, proc1),
  submit_ra_server_state_variable_event(proc2, leader_id, proc1),
  submit_ra_server_state_variable_event(proc1, leader_id, undefined),
  submit_ra_server_state_variable_event(proc2, leader_id, undefined),
  submit_ra_server_state_variable_event(proc2, current_term, 1),
%%  submit_ra_server_state_variable_event(proc1, current_term, 1),
  submit_ra_server_state_variable_event(proc2, leader_id, proc2),
%%  proc1's term is still 1 and leader does not match then
  submit_ra_server_state_variable_event(proc1, leader_id, proc2),
  PropSat = gen_event:call(?ObserverManager, raft_election_safety, get_result),
  gen_event:delete_handler(?ObserverManager, raft_election_safety, []),
  check_result(?FUNCTION_NAME, PropSat, false).

leader_append_only_good_1(_Config) ->
  gen_event:add_handler(?ObserverManager, raft_leader_append_only, [self(), true, true]), % propsat, armed
  submit_ra_server_state_variable_event(proc1, leader_id, proc2),
  submit_ra_log_event(proc1, 0, 1, false, undefined),
  submit_ra_log_event(proc1, 1, 1, false, undefined),
  submit_ra_log_event(proc1, 2, 1, false, undefined),
  submit_ra_log_event(proc2, 0, 1, false, undefined),
  submit_ra_log_event(proc2, 1, 1, false, undefined),
  submit_ra_log_event(proc2, 1, 1, true, undefined),
  submit_ra_server_state_variable_event(proc2, leader_id, proc2),
  submit_ra_log_event(proc2, 2, 1, false, undefined),
  submit_ra_log_event(proc2, 3, 1, false, undefined),
  PropSat = gen_event:call(?ObserverManager, raft_leader_append_only, get_result),
  gen_event:delete_handler(?ObserverManager, raft_leader_append_only, []),
  check_result(?FUNCTION_NAME, PropSat, true).


leader_append_only_bad_1(_Config) ->
  gen_event:add_handler(?ObserverManager, raft_leader_append_only, [self(), true, true]), % propsat, armed
  submit_ra_server_state_variable_event(proc1, leader_id, proc2),
  submit_ra_log_event(proc1, 0, 1, false, undefined),
  submit_ra_log_event(proc1, 1, 1, false, undefined),
  submit_ra_log_event(proc1, 2, 1, false, undefined),
  submit_ra_log_event(proc2, 0, 1, false, undefined),
  submit_ra_log_event(proc2, 1, 1, false, undefined),
  submit_ra_log_event(proc2, 1, 1, true, undefined),
  submit_ra_server_state_variable_event(proc2, leader_id, proc2),
  submit_ra_log_event(proc2, 2, 1, false, undefined),
  submit_ra_log_event(proc2, 2, 1, true, undefined),
  PropSat = gen_event:call(?ObserverManager, raft_leader_append_only, get_result),
  gen_event:delete_handler(?ObserverManager, raft_leader_append_only, []),
  check_result(?FUNCTION_NAME, PropSat, false).


leader_completeness_good_1(_Config) ->
  gen_event:add_handler(?ObserverManager, raft_leader_completeness, [self(), true, true]), % propsat, armed
  submit_ra_log_event(proc1, 0, 0, false, undefined),
  submit_ra_log_event(proc2, 0, 0, false, undefined),
  submit_ra_server_state_variable_event(proc1, commit_index, 0),
  submit_ra_server_state_variable_event(proc1, commit_index, 0),
  submit_ra_server_state_variable_event(proc2, commit_index, 0),
  submit_ra_log_event(proc1, 1, 0, false, undefined),
  submit_ra_server_state_variable_event(proc1, commit_index, 1),
  submit_ra_server_state_variable_event(proc2, commit_index, 1),
  submit_ra_log_event(proc2, 2, 0, false, undefined),
  submit_ra_log_event(proc2, 3, 0, false, undefined),
  submit_ra_server_state_variable_event(proc2, commit_index, 3),
  PropSat = gen_event:call(?ObserverManager, raft_leader_completeness, get_result),
  gen_event:delete_handler(?ObserverManager, raft_leader_completeness, []),
  check_result(?FUNCTION_NAME, PropSat, true).

leader_completeness_bad_1(_Config) ->
  gen_event:add_handler(?ObserverManager, raft_leader_completeness, [self(), true, true]), % propsat, armed
  submit_ra_log_event(proc1, 0, 0, false, undefined),
  submit_ra_log_event(proc2, 0, 0, false, undefined),
  submit_ra_server_state_variable_event(proc1, commit_index, 0),
  submit_ra_server_state_variable_event(proc1, commit_index, 0),
  submit_ra_server_state_variable_event(proc2, commit_index, 0),
  submit_ra_log_event(proc1, 1, 0, false, undefined),
  submit_ra_server_state_variable_event(proc1, commit_index, 1),
  submit_ra_server_state_variable_event(proc2, commit_index, 1),
%%  proc2 writes log to commit_index
  submit_ra_log_event(proc2, 1, 0, false, undefined),
  submit_ra_log_event(proc2, 2, 0, false, undefined),
  submit_ra_server_state_variable_event(proc2, commit_index, 3),
  PropSat = gen_event:call(?ObserverManager, raft_leader_completeness, get_result),
  gen_event:delete_handler(?ObserverManager, raft_leader_completeness, []),
  check_result(?FUNCTION_NAME, PropSat, false).

leader_completeness_bad_2(_Config) ->
  gen_event:add_handler(?ObserverManager, raft_leader_completeness, [self(), true, true]), % propsat, armed
  submit_ra_log_event(proc1, 0, 0, false, undefined),
  submit_ra_log_event(proc2, 0, 0, false, undefined),
  submit_ra_server_state_variable_event(proc1, commit_index, 0),
  submit_ra_server_state_variable_event(proc1, commit_index, 0),
  submit_ra_server_state_variable_event(proc2, commit_index, 0),
  submit_ra_log_event(proc1, 1, 0, false, undefined),
  submit_ra_server_state_variable_event(proc1, commit_index, 1),
  submit_ra_server_state_variable_event(proc2, commit_index, 2),
%%  proc2 has decreasing commit_index
  submit_ra_server_state_variable_event(proc2, commit_index, 1),
  PropSat = gen_event:call(?ObserverManager, raft_leader_completeness, get_result),
  gen_event:delete_handler(?ObserverManager, raft_leader_completeness, []),
  check_result(?FUNCTION_NAME, PropSat, false).


state_machine_safety_good_1(_Config) ->
  gen_event:add_handler(?ObserverManager, raft_state_machine_safety, [self(), true, true]), % propsat, armed
  submit_ra_log_event(proc1, 0, 0, false, undefined),
  submit_ra_log_event(proc2, 0, 0, false, undefined),
  submit_ra_server_state_variable_event(proc1, last_applied, 0),
  submit_ra_server_state_variable_event(proc1, last_applied, 0),
  submit_ra_server_state_variable_event(proc2, last_applied, 0),
  submit_ra_log_event(proc1, 1, 0, false, undefined),
  submit_ra_server_state_variable_event(proc1, last_applied, 1),
  submit_ra_server_state_variable_event(proc2, last_applied, 1),
  submit_ra_log_event(proc2, 2, 0, false, undefined),
  submit_ra_log_event(proc2, 3, 0, false, undefined),
  submit_ra_server_state_variable_event(proc2, last_applied, 3),
  PropSat = gen_event:call(?ObserverManager, raft_state_machine_safety, get_result),
  gen_event:delete_handler(?ObserverManager, raft_state_machine_safety, []),
  check_result(?FUNCTION_NAME, PropSat, true).

state_machine_safety_bad_1(_Config) ->
  gen_event:add_handler(?ObserverManager, raft_state_machine_safety, [self(), true, true]), % propsat, armed
  submit_ra_log_event(proc1, 0, 0, false, undefined),
  submit_ra_log_event(proc2, 0, 0, false, undefined),
  submit_ra_server_state_variable_event(proc1, last_applied, 0),
  submit_ra_server_state_variable_event(proc1, last_applied, 0),
  submit_ra_server_state_variable_event(proc2, last_applied, 0),
  submit_ra_log_event(proc1, 1, 0, false, undefined),
  submit_ra_server_state_variable_event(proc1, last_applied, 1),
  submit_ra_server_state_variable_event(proc2, last_applied, 1),
%%  proc2 writes log to last_applied
  submit_ra_log_event(proc2, 1, 0, false, undefined),
  submit_ra_log_event(proc2, 2, 0, false, undefined),
  submit_ra_server_state_variable_event(proc2, last_applied, 3),
  PropSat = gen_event:call(?ObserverManager, raft_state_machine_safety, get_result),
  gen_event:delete_handler(?ObserverManager, raft_state_machine_safety, []),
  check_result(?FUNCTION_NAME, PropSat, false).

state_machine_safety_bad_2(_Config) ->
  gen_event:add_handler(?ObserverManager, raft_state_machine_safety, [self(), true, true]), % propsat, armed
  submit_ra_log_event(proc1, 0, 0, false, undefined),
  submit_ra_log_event(proc2, 0, 0, false, undefined),
  submit_ra_server_state_variable_event(proc1, last_applied, 0),
  submit_ra_server_state_variable_event(proc1, last_applied, 0),
  submit_ra_server_state_variable_event(proc2, last_applied, 0),
  submit_ra_log_event(proc1, 1, 0, false, undefined),
  submit_ra_server_state_variable_event(proc1, last_applied, 1),
  submit_ra_server_state_variable_event(proc2, last_applied, 2),
%%  proc2 has decreasing last_applied
  submit_ra_server_state_variable_event(proc2, last_applied, 1),
  PropSat = gen_event:call(?ObserverManager, raft_state_machine_safety, get_result),
  gen_event:delete_handler(?ObserverManager, raft_state_machine_safety, []),
  check_result(?FUNCTION_NAME, PropSat, false).


log_matching_good_1(_Config) ->
  gen_event:add_handler(?ObserverManager, raft_log_matching, [self(), true, true]), % propsat, armed
  submit_ra_log_event(proc1, 1, 0, false, data1),
  submit_ra_log_event(proc2, 1, 0, false, data1),
  submit_ra_log_event(proc1, 2, 1, false, data2),
  submit_ra_log_event(proc2, 2, 2, false, data3),
  submit_ra_log_event(proc2, 2, 1, true, data2),
  PropSat = gen_event:call(?ObserverManager, raft_log_matching, get_result),
  gen_event:delete_handler(?ObserverManager, raft_log_matching, []),
  check_result(?FUNCTION_NAME, PropSat, true).

log_matching_bad_1(_Config) ->
  gen_event:add_handler(?ObserverManager, raft_log_matching, [self(), true, true]), % propsat, armed
  submit_ra_log_event(proc1, 1, 0, false, data1),
  submit_ra_log_event(proc2, 1, 0, false, data1),
  submit_ra_log_event(proc1, 2, 1, false, data2),
  submit_ra_log_event(proc2, 2, 1, false, data3),
  submit_ra_log_event(proc2, 2, 1, true, data2),
  PropSat = gen_event:call(?ObserverManager, raft_log_matching, get_result),
  gen_event:delete_handler(?ObserverManager, raft_log_matching, []),
  check_result(?FUNCTION_NAME, PropSat, false).

%%  internal helper with mocked process id
submit_ra_server_state_variable_event(Proc, StateVariable, Value) ->
  RaServerStateVariableEvent = #ra_server_state_variable_obs_event{
    state_variable=StateVariable, value=Value},
  gen_event:sync_notify(?ObserverManager,
    {process, #obs_process_event{process=Proc, event_type=ra_server_state_variable,
      event_content=RaServerStateVariableEvent}}).


submit_ra_log_event(Proc, Idx, Term, Trunc, Data) ->
  RaLogEvent = #ra_log_obs_event{idx=Idx, term=Term, trunc=Trunc, data=Data},
  gen_event:sync_notify({global, om},
  {process, #obs_process_event{process=Proc, event_type=ra_log, event_content=RaLogEvent}}).


check_result(FunctionName, PropSat, GoalSat) ->
  case PropSat of
    GoalSat -> ok;
    false -> ct:fail("Property did not hold but it should in ~p!", [FunctionName]);
    true -> ct:fail("Property did hold but it should not in ~p!", [FunctionName])
  end.