-type participant() :: nonempty_string().
-type log_entry() :: {Index :: integer(), Data :: any()}.
-type raft_node_state() :: recover | recovered | leader | pre_vote | candidate | follower |
receive_snapshot | await_condition | terminating_leader | terminating_follower.

-record(log_tree, { % root always has "undefined" data -> option for multiple children on 1st level
    data = undefined :: log_entry() | undefined,
    end_parts = [] :: [any()],
    voted_parts = [] :: [{any(), any()}],
    commit_index_parts = [] :: [any()],
    children = [] :: [#log_tree{}],
    data_div_children = false :: boolean()
}).

-record(per_part_abs_info, {
    role :: raft_node_state(),
    commit_index :: integer(),
    voted_for_less :: true | false | not_given,
    term = undefined :: integer() | undefined
}).

-record(abs_log_tree, { % root also may have multiple children in abstract state
    part_info = [] :: [#per_part_abs_info{}],
    children = [] :: [#log_tree{}] % TODO: abs_log_tree?
}).

-record(per_part_state, {
    log = array:new({default, undefined}) :: array:array(log_entry()),
    state = recover :: raft_node_state(),
    commit_index = 0 :: integer(),
    current_term = 0 :: integer(),
    voted_for = undefined :: participant() | undefined
}).
