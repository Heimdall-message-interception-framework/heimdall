-module(raft_abstract_state_predicate).
-behaviour(gen_event).

-include("observer_events.hrl").
-include("sched_event.hrl").
-include("raft_observer_events.hrl").

-dialyzer(underspecs).

-export([init/1, handle_call/2, handle_event/2]).

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
  children = [] :: [#log_tree{}]
}).

-record(per_part_state, {
  log = array:new({default, undefined}) :: array:array(log_entry()),
  state = recover :: raft_node_state(),
  commit_index = 0 :: integer(),
  current_term = 0 :: integer(),
  voted_for = undefined :: participant() | undefined
}).

-record(state, {
    history_of_events = queue:new() :: queue:queue({'process', #obs_process_event{}} | {'sched', #sched_event{}}),
    all_participants = [] :: [participant()],
    part_to_state_map = maps:new() :: #{participant() => #per_part_state{}}
}).

-spec init(_) -> {'ok', #state{}}.
init(_) ->
    {ok, #state{}}.

%% listen to registration of ra_server_proc but no other sched events
-spec handle_event({sched, #sched_event{}}, #state{}) -> {'ok', #state{}};
                  ({process, #obs_process_event{}}, #state{}) -> {ok, #state{}}.
handle_event({sched,
  #sched_event{what = reg_node, class = ra_server_proc, name = ProcName} = SchedEvent},
    #state{all_participants = AllParts, part_to_state_map = PartStateMap} = State) ->
  logger:info("[~p] new ra_server_pro ~p registered.", [?MODULE, ProcName]),
%%    store event in history of events
  State1 = add_to_history(State, {sched, SchedEvent}),
%%  update all participants and state map
  AllParts1 = [ProcName | AllParts],
  PartStateMap1 = maps:put(ProcName, #per_part_state{}, PartStateMap),
  State2 = State1#state{all_participants = AllParts1, part_to_state_map = PartStateMap1},
  {ok, State2};
%% listen to process event updates
handle_event({process,
              #obs_process_event{process = _Proc, event_type = _EvType, event_content = _EvContent} = ProcEvent},
              #state{} = State) ->
%%    store event in history of events
  State1 = add_to_history(State, {process, ProcEvent}),
%%    TO ADD: for process events
  State2 = update_state(State1, ProcEvent),
  {ok, State2};
%%
handle_event(_Event, State) ->
    {ok, State}.

-spec handle_call(get_result, #state{}) -> {ok, {#log_tree{}, #abs_log_tree{}}, #state{}};
                 (get_length_history, #state{}) -> {ok, integer(), #state{}}.
handle_call(get_result, #state{} = State) ->
    Stage1 = build_1st_stage(State),   % build log-tree one by one with commit-index
    check_stage_has_all_comm_and_end(Stage1, State),
    Stage2 = build_2nd_stage(Stage1),
    Stage3 = build_3rd_stage(Stage2),  % collapse entries
    Stage4 = build_4th_stage(Stage3, State),
    AbstractLogTree = build_5th_stage(Stage4),
    ConcreteLogTree = Stage1,
    {ok, {ConcreteLogTree, AbstractLogTree}, State};
handle_call(get_length_history, #state{history_of_events = HistoryOfEvents} = State) ->
    {ok, queue:len(HistoryOfEvents), State};
handle_call(Msg, State) ->
    io:format("[raft_observer] received unhandled call: ~p~n", [Msg]),
    {ok, ok, State}.

-spec add_to_history(#state{}, {'process', #obs_process_event{}} | {'sched', #sched_event{}}) -> #state{}.
add_to_history(State, GeneralEvent) ->
    NewHistory = queue:in(GeneralEvent, State#state.history_of_events),
    State#state{history_of_events = NewHistory}.

-spec update_state(#state{}, #obs_process_event{}) -> #state{}.
update_state(State,
    #obs_process_event{process = ProcPid, event_type = EvType, event_content = EvContent}) ->
  % Extract participant's name (as atom) from ProcPid
  ProcName = message_interception_layer:get_name_for_pid(ProcPid),
  State1 = case EvType of
    ra_log -> handle_ra_log(State, ProcName, EvContent);
    ra_machine_state_update -> State;
    ra_machine_reply_write -> State;
    ra_machine_reply_read -> State;
    ra_machine_side_effects -> State;
    ra_server_state_variable -> handle_ra_state_variable(State, ProcName, EvContent);
    statem_transition_event -> handle_statem_transition(State, ProcName, EvContent);
    statem_stop_event -> State;
    _ -> erlang:throw("unhandled type of event")
  end,
  State1.

-spec handle_ra_log(#state{}, participant(), #ra_log_obs_event{}) -> #state{}.
handle_ra_log(State = #state{part_to_state_map = PartStateMap}, Part,
    #ra_log_obs_event{idx = Idx, term = Term, data = Data, trunc = Trunc}) ->
  PartRecord = maps:get(Part, PartStateMap),
  PartLog = PartRecord#per_part_state.log,
  PartLog1 = case Trunc of
    true -> array:resize(Idx); % Idx starts at 0 but we truncate one before current Idx
    false -> PartLog
  end,
%%  sanity check for log entries
  case array:size(PartLog1) =< Idx of
    false -> logger:info("[~p, ~p]: writing log entry opens 'hole'; log: ~p; index: ~p",
                          [?MODULE, ?LINE, array:to_list(PartLog1), Idx]);
    true -> ok
  end,
  PartLog2 = array:set(Idx, {Term, Data}, PartLog1),
  PartRecord1 = PartRecord#per_part_state{log = PartLog2},
  PartStateMap1 = maps:update(Part, PartRecord1, PartStateMap),
  State#state{part_to_state_map = PartStateMap1}.

-spec handle_ra_state_variable(#state{}, participant(), #ra_server_state_variable_obs_event{}) -> #state{}.
handle_ra_state_variable(State = #state{part_to_state_map = PartStateMap}, Proc,
    #ra_server_state_variable_obs_event{state_variable = current_term, value = Value}) ->
  PartRecord = maps:get(Proc, PartStateMap),
  PartRecord1 = PartRecord#per_part_state{current_term = Value},
  PartStateMap1 = maps:update(Proc, PartRecord1, PartStateMap),
  State#state{part_to_state_map = PartStateMap1};
handle_ra_state_variable(State = #state{part_to_state_map = PartStateMap}, Proc,
    #ra_server_state_variable_obs_event{state_variable = commit_index, value = Value}) ->
  PartRecord = maps:get(Proc, PartStateMap),
  PartRecord1 = PartRecord#per_part_state{commit_index = Value},
  PartStateMap1 = maps:update(Proc, PartRecord1, PartStateMap),
  State#state{part_to_state_map = PartStateMap1};
handle_ra_state_variable(State = #state{part_to_state_map = PartStateMap}, Proc,
    #ra_server_state_variable_obs_event{state_variable = voted_for, value = Value}) ->
  PartRecord = maps:get(Proc, PartStateMap),
  ActualValue = case Value of
    {ActualValue1, _} -> ActualValue1; % TODO: this is a hack because of bad naming scheme in ra
    Other -> Other
  end,
  VotedForString =
    if
       ActualValue =:= undefined -> undefined;
       % transform voted_for identifier to String if needed
       is_atom(ActualValue) -> atom_to_list(ActualValue);
       is_list(ActualValue) -> ActualValue end,
  PartRecord1 = PartRecord#per_part_state{voted_for = VotedForString},
  PartStateMap1 = maps:update(Proc, PartRecord1, PartStateMap),
  State#state{part_to_state_map = PartStateMap1};
handle_ra_state_variable(State, _Proc, #ra_server_state_variable_obs_event{state_variable = _}) ->
  State.

-spec handle_statem_transition(#state{}, participant(), #statem_transition_event{}) -> #state{}.
handle_statem_transition(State = #state{part_to_state_map = PartStateMap}, Proc,
    #statem_transition_event{state = {next_state, NewState}}) ->
  PartRecord = maps:get(Proc, PartStateMap),
  PartRecord1 = PartRecord#per_part_state{state = NewState},
  PartStateMap1 = maps:update(Proc, PartRecord1, PartStateMap),
  State#state{part_to_state_map = PartStateMap1};
handle_statem_transition(State, _Proc, #statem_transition_event{state = {_, _}}) ->
  State.

-spec build_1st_stage(#state{}) -> #log_tree{}.
build_1st_stage(#state{part_to_state_map = PartStateMap} = _State) ->
  LogExtractorFunc = fun(_Proc, Rec) -> array:to_list(Rec#per_part_state.log) end,
  PartToLogMap = maps:map(LogExtractorFunc, PartStateMap),
  InitialLogTree = #log_tree{}, % data = undefined, children = []
  LogTree = maps:fold(fun(Proc, Log, LogTreeAcc) ->
                        CommitIndex = (maps:get(Proc, PartStateMap))#per_part_state.commit_index,
                        VotedFor = (maps:get(Proc, PartStateMap))#per_part_state.voted_for,
                        add_log_to_log_tree(LogTreeAcc, Log, Proc, CommitIndex, VotedFor)
                      end, InitialLogTree, PartToLogMap),
  LogTree.

%% case 1: data is undefined, no children and log empty
-spec add_log_to_log_tree(CurrentLogTree :: #log_tree{}, LogToAdd :: [log_entry()], participant(), integer(), participant()) -> #log_tree{}.
add_log_to_log_tree(LogTree =
  #log_tree{data = undefined, children = [], end_parts = EndParts, voted_parts = VotedParts, commit_index_parts = CommIndexParts},
  _LogToAdd = [], Proc, CommitIndex, VotedFor) ->
  case CommitIndex of
    0 -> LogTree#log_tree{end_parts = [Proc | EndParts], voted_parts = [{Proc, VotedFor}, VotedParts], commit_index_parts = [Proc | CommIndexParts]};
    _ -> % if not 0, something went wrong
        erlang:throw("participant with empty log but non-zero commit-index")
  end;
%% case 2: data is undefined, no children and log not empty
add_log_to_log_tree(LogTree =
  #log_tree{data = undefined, children = [], commit_index_parts = CommitIndexParts},
  LogToAdd, Proc, CommitIndex, VotedFor) ->
  % go over LogToAdd and turn it into log_tree
  Child = turn_log_to_log_tree(LogToAdd, Proc, CommitIndex-1, VotedFor),
  logger:debug("[~p] converted log of ~p to logtree ~p", [?MODULE, Proc, Child]),
  CommIndexParts1 = case CommitIndex == 0 of
                      true -> [Proc | CommitIndexParts];
                      false -> CommitIndexParts
                    end,
  LogTree#log_tree{children = [Child], commit_index_parts = CommIndexParts1};
%% case 3: log is empty
add_log_to_log_tree(LogTree =
  #log_tree{end_parts = EndParts, commit_index_parts = CommitIndexParts},
  _LogToAdd = [], Proc, CommitIndex, VotedFor) ->
  EndParts1 = [Proc | EndParts],
  VotedParts1 = [{Proc, VotedFor} | EndParts],
  CommIndexParts1 = case CommitIndex == 0 of
                      true -> [Proc | CommitIndexParts];
                      false -> CommitIndexParts
                    end,
  LogTree#log_tree{end_parts = EndParts1, voted_parts = VotedParts1, commit_index_parts = CommIndexParts1};
%% case 4: log and children not empty so check and recurse
add_log_to_log_tree(LogTree = #log_tree{children = Children, commit_index_parts = CommitIndexParts},
    LogToAdd, Proc, CommitIndex, VotedFor) ->
  %%  attempt to add to some of the children
  ResultsChildren = lists:map(fun(Child) ->
                                add_log_to_child(LogToAdd, Child, Proc, CommitIndex - 1, VotedFor)
                              end, Children),
  {Results, Children1} = lists:unzip(ResultsChildren),
  Children2 = case lists:member(true, Results) of
    true -> % was inserted so everything fine
      Children1;
    false -> % was not inserted so add child for the log to add
      LogTreeToAdd = turn_log_to_log_tree(LogToAdd, Proc, CommitIndex, VotedFor),
      ComparisonFunc = fun(LT1, LT2) -> (max_term_in_log_tree(LT1) =< max_term_in_log_tree(LT2)) end,
      lists:sort(ComparisonFunc, [LogTreeToAdd | Children])
  end,
  CommIndexParts1 = case CommitIndex == 0 of
                   true -> [Proc | CommitIndexParts];
                   false -> CommitIndexParts
                 end,
  LogTree#log_tree{children = Children2, commit_index_parts = CommIndexParts1}.

-spec turn_log_to_log_tree(nonempty_list(), participant(), integer(), participant()) -> #log_tree{}.
turn_log_to_log_tree([Entry | Log], Proc, CommitIndex, VotedFor) ->
  LogTree = case CommitIndex == 0 of
              true -> #log_tree{data=Entry, commit_index_parts = [Proc]};
              false -> #log_tree{data=Entry}
            end,
  case Log of
    [] -> LogTree#log_tree{end_parts = [Proc], voted_parts = [{Proc, VotedFor}],  children = []};
    _ -> LogTree#log_tree{children = [turn_log_to_log_tree(Log, Proc, CommitIndex - 1, VotedFor)]}
  end.

-spec add_log_to_child(nonempty_list(), #log_tree{}, _, integer(), participant()) -> {'false' | 'true', #log_tree{}}.
add_log_to_child([Entry | RemLogToAdd], LogTree = #log_tree{data = Data}, Proc, CommitIndex, VotedFor) ->
  DataMatches = Entry == Data,
  LogTree1 = case DataMatches of
    true -> % recursively descend
      add_log_to_log_tree(LogTree, RemLogToAdd, Proc, CommitIndex, VotedFor);
    false ->
      LogTree
  end,
  {DataMatches, LogTree1}.

-spec max_term_in_log_tree(#log_tree{}) -> any().
max_term_in_log_tree(#log_tree{data = {Index, _Data}, children = []}) ->
  Index;
max_term_in_log_tree(#log_tree{data = {Index, _Data}, children = Children}) ->
  MaxTermsChildren = lists:map(fun(LT) -> max_term_in_log_tree(LT) end, Children),
  lists:max([Index, MaxTermsChildren]).

-spec build_2nd_stage(#log_tree{}) -> #log_tree{}.
build_2nd_stage(LogTree = #log_tree{children = Children}) ->
  TermExtractorFunc = fun(#log_tree{data = {Term, _Data}}) -> Term end,
  TermList = lists:map(TermExtractorFunc, Children),
  TermSet = sets:from_list(TermList),
  % if children diverge on data at this point, there is duplicate term so lenghts differ
  LogTree#log_tree{data_div_children = not (length(TermList) == sets:size(TermSet))}.

%% last case(s)
-spec build_3rd_stage(#log_tree{}) -> #log_tree{}.
build_3rd_stage(PrevLogTree = #log_tree{data = undefined, children = []}) ->
  PrevLogTree;
%% initial case
build_3rd_stage(PrevLogTree = #log_tree{data = undefined, children = Children}) ->
  PrevLogTree#log_tree{children = lists:map(fun(Child) -> build_3rd_stage(Child) end, Children)};
%% intermediate cases
build_3rd_stage(PrevLogTree =
  #log_tree{end_parts = EndParts, commit_index_parts = CommIndexParts, children = Children}) ->
  case (EndParts == []) and (CommIndexParts == []) and (length(Children) == 1) of
    true -> % collapse this entry (do only collapse if there is a branch so no bubbling up of children)
      [Child] = Children,
      build_3rd_stage(Child);
    false -> % do not collapse and just recurse
      PrevLogTree#log_tree{children =
                           lists:map(fun(Child) -> build_3rd_stage(Child) end, Children)}
  end.


-spec build_4th_stage(#log_tree{}, #state{}) -> #abs_log_tree{}.
build_4th_stage(PrevLogTree, State) ->
  build_4th_stage(PrevLogTree, State, maps:new(), 0).
-spec build_4th_stage(#log_tree{}, #state{}, #{}, non_neg_integer()) -> #abs_log_tree{}.
build_4th_stage(#log_tree{commit_index_parts = CommIndexParts, children = Children, end_parts = EndParts},
    State = #state{part_to_state_map = PartStateMap}, MapProcCommIndex, DistanceFromRoot) ->
  MapProcCommIndex1 = lists:foldl(fun(Proc, MapProcCommIndexAcc) -> maps:put(Proc, DistanceFromRoot, MapProcCommIndexAcc) end,
            MapProcCommIndex, CommIndexParts),
  PartsInfo = lists:sort(lists:map(fun(Proc) ->
                          PartRecord = maps:get(Proc, PartStateMap),
                          VotedForLess = case PartRecord#per_part_state.voted_for of
                                           undefined -> not_given;
                                           Other ->
                                             OtherRecord = maps:get(Other, PartStateMap),
                                             OtherRecord#per_part_state.commit_index =< array:size(PartRecord#per_part_state.log)
                                             % TODO: does size for array work?
                                             % according to paper, Raft even checks the length of logs, not only prefix with committed
                                             % but the latter is used in TLA safety specs
                                         end,
                          #per_part_abs_info{
                            role = PartRecord#per_part_state.state,
                            commit_index = case maps:get(Proc, MapProcCommIndex1, undefined) of
                              undefined -> logger:info("[~p] proc ~p has undefined commit index. Maybe it was longer than its log and was discarded.", [?MODULE, Proc]),
                                           undefined;
                              CommitIndex -> CommitIndex end,
                            term = PartRecord#per_part_state.current_term,
                            voted_for_less = VotedForLess
                          }
                        end,
                        EndParts)),
  AbsChildren = lists:map(
    fun(Child) -> build_4th_stage(Child, State, MapProcCommIndex1, DistanceFromRoot + 1) end,
    Children),
  #abs_log_tree{part_info = PartsInfo, children = AbsChildren}.


-spec build_5th_stage(#abs_log_tree{}) -> #abs_log_tree{}.
build_5th_stage(AbsLogTree) ->
  AllLeaderTermsSet = get_all_leader_terms(AbsLogTree),
  AllLeaderTermsSorted = lists:sort(sets:to_list(AllLeaderTermsSet)),
  MapLeaderTermDummyTerm = maps:from_list(lists:zip(
    AllLeaderTermsSorted, lists:seq(1, length(AllLeaderTermsSorted))
  )),
  build_5th_stage_rec(AbsLogTree, MapLeaderTermDummyTerm).

-spec build_5th_stage_rec(#abs_log_tree{}, #{}) -> #abs_log_tree{}.
build_5th_stage_rec(AbsLogTree = #abs_log_tree{part_info = PartInfo, children = Children}, MapLeaderTermDummyTerm) ->
  PartInfo1 = lists:map(
    fun(PerPartInfo = #per_part_abs_info{role = State, term = CurrentTerm}) ->
      case State == leader of
        true -> PerPartInfo#per_part_abs_info{term = maps:get(CurrentTerm, MapLeaderTermDummyTerm)};
        false -> PerPartInfo#per_part_abs_info{term = undefined}
      end
    end,
    PartInfo),
  Children1 = lists:map(fun(Child) -> build_5th_stage(Child) end, Children),
  AbsLogTree#abs_log_tree{part_info = PartInfo1, children = Children1}.

-spec get_all_leader_terms(#abs_log_tree{}) -> sets:set(#per_part_abs_info{}).
get_all_leader_terms(AbsLogTree) ->
  ListProcInfo = get_all_proc_info_rec(AbsLogTree),
  TermAccFunc = fun(#per_part_abs_info{role = State, term = Term}, Acc) -> case State == leader of
                                               true -> sets:add_element(Term, Acc);
                                               false -> Acc
                                             end end,
  LeaderTermsSet = lists:foldl(TermAccFunc, sets:new(), ListProcInfo),
  LeaderTermsSet.

-spec get_all_proc_info_rec(#abs_log_tree{}) -> [#per_part_abs_info{}].
get_all_proc_info_rec(#abs_log_tree{children = Children, part_info = PartInfo}) ->
  ChildrenInfo = lists:append(lists:map(fun(Child) -> get_all_proc_info_rec(Child) end, Children)),
  lists:append(PartInfo, ChildrenInfo).

%% functions for sanity checks
-spec check_stage_has_all_comm_and_end(#log_tree{}, #state{}) -> 'ok'.
check_stage_has_all_comm_and_end(Stage, State) ->
  {EndParts, CommParts} = compute_endparts_and_commparts(Stage),
  AllPartsSet = sets:from_list(State#state.all_participants),
  case EndParts == AllPartsSet of
    true -> ok;
    false ->
      Missing = sets:to_list(sets:subtract(AllPartsSet, EndParts)),
      logger:warning("[~p] Obtained Stage with missing End part for ~p. Stage: ~p", [?MODULE, Missing, Stage]),
      logger:info(["Stage", Stage])
  end,
  case CommParts == AllPartsSet of
    true -> ok;
    false ->
      MissingCom = sets:to_list(sets:subtract(AllPartsSet, CommParts)),
      logger:debug("[~p] Obtained Stage with missing Comm part for ~p. Stage: ~p", [?MODULE, MissingCom, Stage]),
      logger:debug("[~p] History of events: ~p", [?MODULE, State#state.history_of_events]),
      logger:debug("[~p] Part to state map is: ~p", [?MODULE, State#state.part_to_state_map])
  end,
  ok.

-spec compute_endparts_and_commparts(#log_tree{}) -> {sets:set(participant()), sets:set(participant())}.
compute_endparts_and_commparts(#log_tree{children = Children, end_parts = EndParts, commit_index_parts = CommParts}) ->
  lists:foldl(
    fun(Child, {EndPartsAcc, CommPartsAcc}) ->
      {ChildEndParts, ChildCommParts} = compute_endparts_and_commparts(Child),
      {sets:union(EndPartsAcc, ChildEndParts), sets:union(CommPartsAcc, ChildCommParts)}
    end,
    {sets:from_list(EndParts), sets:from_list(CommParts)},
    Children
  ).

