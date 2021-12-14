-module(raft_abstract_state_predicate).
-behaviour(gen_event).

-include("observer_events.hrl").
-include("sched_event.hrl").
-include("raft_observer_events.hrl").

-export([init/1, handle_call/2, handle_event/2]).

-record(log_tree, { % let the root always have undefined data (option for multiple children on 1st level)
  data = undefined :: any() | undefined,
  end_parts = [] :: lists:list(any()),
  commit_index_parts = [] :: lists:list(any()),
  children = [] :: lists:list(#log_tree{}),
  data_div_children = false :: boolean()
}).

-record(per_part_abs_info, {
  role :: any(),
  commit_index :: any(),
  voted_for_less :: true | false | not_given,
  term = undefined :: any() | undefined
}).

-record(abs_log_tree, { % let the root always have undefined data (option for multiple children on 1st level)
  part_info = [] :: lists:list(#per_part_abs_info{}),
  children = [] :: lists:list(#log_tree{})
}).

-record(per_part_state, {
  log = array:new({default, undefined}) :: array:array(any()),
  state = recover :: any(), % is initial state of ra_server_proc, TODO: all possible states
  commit_index = 0 :: integer(),
  current_term = 0 :: integer(),
  voted_for = undefined :: integer() | undefined
}).

-record(state, {
    history_of_events = queue:new() :: queue:queue(),
    all_participants = [] :: lists:lists(any()),
    part_to_state_map = maps:new() :: maps:map(any(), #per_part_state{})
    }).

%%    TO ADD: initialise added fields if necessary
init(_) ->
    {ok, #state{}}.

%% listen to registration of ra_server_proc but no other sched events
handle_event({sched,
  #sched_event{what = reg_node, name = Name, class = ra_server_proc} = SchedEvent},
    #state{all_participants = AllParts, part_to_state_map = PartStateMap} = State) ->
%%    store event in history of events
  State1 = add_to_history(State, {sched, SchedEvent}),
%%  update all participants and state map
  AllParts1 = [Name | AllParts],
  PartStateMap1 = maps:put(Name, #per_part_state{}, PartStateMap),
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

handle_call(get_result, #state{} = State) ->
%%    erlang:display(["History", State#state.history_of_events]),
%%    lists:foreach(fun(Proc) ->
%%      PartRec = maps:get(Proc, State#state.part_to_state_map),
%%      erlang:display(["Proc", Proc, "Log", array:to_list(PartRec#per_part_state.log)])
%%      end, State#state.all_participants),
    Stage1 = build_1st_stage(State),   % build log-tree one by one with commit-index
    check_stage_has_all_comm_and_end(Stage1, State#state.all_participants),
    Stage1P = build_int_stage(Stage1),
    Stage2 = build_2nd_stage(Stage1P),  % collapse entries
    check_stage_has_all_comm_and_end(Stage1, State#state.all_participants),
%%    case Stage1 == Stage2 of
%%      true -> ok;
%%      false -> erlang:display(["Stage1", Stage1]),
%%        erlang:display(["Stage2", Stage2])
%%    end,
    Stage3 = build_3rd_stage(Stage2, State),  % switch to "root-view" for commit-index, remove data and
                                              % substitute part's by their roles (leader etc.)
    Stage4 = build_4th_stage(Stage3),
%%    dummy map as result for now
    DummyResult = maps:from_list([{abstract_state, Stage4}]),
    {ok, DummyResult, State};
handle_call(get_length_history, #state{history_of_events = HistoryOfEvents} = State) ->
    {ok, queue:len(HistoryOfEvents), State};
handle_call(Msg, State) ->
    io:format("[raft_observer] received unhandled call: ~p~n", [Msg]),
    {ok, ok, State}.

add_to_history(State, GeneralEvent) ->
    NewHistory = queue:in(GeneralEvent, State#state.history_of_events),
    State#state{history_of_events = NewHistory}.

update_state(State = #state{all_participants = AllParts},
    #obs_process_event{process = Proc, event_type = EvType, event_content = EvContent}) ->
  ProcName1 = case lists:member(Proc, AllParts) of
    false -> message_interception_layer:get_name_for_pid(Proc);
    true -> Proc
  end,
  State1 = case EvType of
    ra_log -> handle_ra_log(State, ProcName1, EvContent);
    ra_machine_state_update -> State;
    ra_machine_reply_write -> State;
    ra_machine_reply_read -> State;
    ra_machine_side_effects -> State;
    ra_server_state_variable -> handle_ra_state_variable(State, ProcName1, EvContent);
    statem_transition_event -> handle_statem_transition(State, ProcName1, EvContent);
    statem_stop_event -> State;
    _ -> erlang:display("unhandled type of event")
  end,
  State1.

handle_ra_log(State = #state{part_to_state_map = PartStateMap}, Proc,
    #ra_log_obs_event{idx = Idx, term = Term, data = Data, trunc = Trunc}) ->
  PartRecord = maps:get(Proc, PartStateMap),
  PartLog = PartRecord#per_part_state.log,
  PartLog1 = case Trunc of
    true -> array:resize(Idx); % Idx starts at 0 but we truncate one before current Idx
    false -> PartLog
  end,
%%  sanity check for log entries
  case array:size(PartLog1) == Idx of
    false -> erlang:display("log entry will not be written to next position");
    true -> ok
  end,
  PartLog2 = array:set(Idx, {Term, Data}, PartLog1),
  PartRecord1 = PartRecord#per_part_state{log = PartLog2},
  PartStateMap1 = maps:update(Proc, PartRecord1, PartStateMap),
  State#state{part_to_state_map = PartStateMap1}.

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
  erlang:display(["voted for updated", "voted_for", Value, "Proc", Proc]),
  PartRecord = maps:get(Proc, PartStateMap),
  ActualValue = case Value of
    {ActualValue1, _} -> ActualValue1; % TODO: this is a hack because of bad naming schemes
    Other -> Other
  end,
  PartRecord1 = PartRecord#per_part_state{voted_for = ActualValue},
  PartStateMap1 = maps:update(Proc, PartRecord1, PartStateMap),
  State#state{part_to_state_map = PartStateMap1};
handle_ra_state_variable(State, _Proc, #ra_server_state_variable_obs_event{state_variable = _}) ->
  State.

handle_statem_transition(State = #state{part_to_state_map = PartStateMap}, Proc,
    #statem_transition_event{state = {next_state, NewState}}) ->
  PartRecord = maps:get(Proc, PartStateMap),
  PartRecord1 = PartRecord#per_part_state{state = NewState},
  PartStateMap1 = maps:update(Proc, PartRecord1, PartStateMap),
  State#state{part_to_state_map = PartStateMap1};
handle_statem_transition(State, _Proc, #statem_transition_event{state = {_, _}}) ->
  State.

build_1st_stage(#state{part_to_state_map = PartStateMap} = _State) ->
  LogExtractorFunc = fun(_Proc, Rec) -> array:to_list(Rec#per_part_state.log) end,
  PartToLogMap = maps:map(LogExtractorFunc, PartStateMap),
  InitialLogTree = #log_tree{}, % data = undefined, children = []
  LogTree = maps:fold(fun(Proc, Log, LogTreeAcc) ->
                        CommitIndex = (maps:get(Proc, PartStateMap))#per_part_state.commit_index,
                        add_log_to_log_tree(LogTreeAcc, Log, Proc, CommitIndex)
                      end, InitialLogTree, PartToLogMap),
  LogTree.

%% case 1: data is undefined, no children and log empty
add_log_to_log_tree(LogTree =
  #log_tree{data = undefined, children = [], end_parts = EndParts, commit_index_parts = CommIndexParts},
  _LogToAdd = [], Proc, CommitIndex) ->
  case CommitIndex of
    0 -> LogTree#log_tree{end_parts = [Proc | EndParts], commit_index_parts = [Proc | CommIndexParts]};
    _ -> % if not 0, something went wrong
        erlang:throw("participant with empty log but non-yweo commit-index")
  end;
%% case 2: data is undefined, no children and log not empty
add_log_to_log_tree(LogTree =
  #log_tree{data = undefined, children = []},
  LogToAdd, Proc, CommitIndex) ->
  % go over LogToAdd and turn it into log_tree
  Child = turn_log_to_log_tree(LogToAdd, Proc, CommitIndex),
  LogTree#log_tree{children = [Child]};
%% case 3: log is empty
add_log_to_log_tree(LogTree =
  #log_tree{end_parts = EndParts, commit_index_parts = CommitIndexParts},
  _LogToAdd = [], Proc, CommitIndex) ->
  EndParts1 = [Proc | EndParts],
  CommIndexParts1 = case CommitIndex == 0 of
                      true -> [Proc | CommitIndexParts];
                      false -> CommitIndexParts
                    end,
  LogTree#log_tree{end_parts = EndParts1, commit_index_parts = CommIndexParts1};
%% case 4: log and children not empty so check and recurse
add_log_to_log_tree(LogTree = #log_tree{children = Children, commit_index_parts = CommitIndexParts}, LogToAdd, Proc, CommitIndex) ->
  %%  attempt to add to some of the children
  ResultsChildren = lists:map(fun(Child) -> add_log_to_child(LogToAdd, Child, Proc, CommitIndex - 1) end, Children),
  {Results, Children1} = lists:unzip(ResultsChildren),
  Children2 = case lists:member(true, Results) of
    true -> % was inserted so everything fine
      Children1;
    false -> % was not inserted so add child for the log to add
      LogTreeToAdd = turn_log_to_log_tree(LogToAdd, Proc, CommitIndex),
      ComparisonFunc = fun(LT1, LT2) -> (max_term_in_log_tree(LT1) =< max_term_in_log_tree(LT2)) end,
      lists:sort(ComparisonFunc, [LogTreeToAdd | Children])
  end,
  CommIndexParts1 = case CommitIndex == 0 of
                   true -> [Proc | CommitIndexParts];
                   false -> CommitIndexParts
                 end,
  LogTree#log_tree{children = Children2, commit_index_parts = CommIndexParts1}.

turn_log_to_log_tree([Entry | Log], Proc, CommitIndex) ->
  LogTree = case CommitIndex == 0 of
              true -> #log_tree{data=Entry, commit_index_parts = [Proc]};
              false -> #log_tree{data=Entry}
            end,
  case Log of
    [] -> LogTree#log_tree{end_parts = [Proc], children = []};
    _ -> LogTree#log_tree{children = [turn_log_to_log_tree(Log, Proc, CommitIndex - 1)]}
  end.

add_log_to_child([Entry | RemLogToAdd], LogTree = #log_tree{data = Data}, Proc, CommitIndex) ->
  DataMatches = Entry == Data,
  LogTree1 = case DataMatches of
    true -> % recursively descend
      add_log_to_log_tree(LogTree, RemLogToAdd, Proc, CommitIndex);
    false ->
      LogTree
  end,
  {DataMatches, LogTree1}.

max_term_in_log_tree(#log_tree{data = {Index, _Data}, children = []}) ->
  Index;
max_term_in_log_tree(#log_tree{data = {Index, _Data}, children = Children}) ->
  MaxTermsChildren = lists:map(fun(LT) -> max_term_in_log_tree(LT) end, Children),
  lists:max([Index, MaxTermsChildren]).

build_int_stage(LogTree = #log_tree{children = Children}) ->
  TermExtractorFunc = fun(#log_tree{data = {Term, _Data}}) -> Term end,
  TermList = lists:map(TermExtractorFunc, Children),
  TermSet = sets:from_list(TermList),
%%    if children diverge on data at this point, there is duplicate term
  LogTree#log_tree{data_div_children = not (length(TermList) == sets:size(TermSet))}.

%% last case(s)
build_2nd_stage(PrevLogTree = #log_tree{data = undefined, children = []}) ->
  PrevLogTree;
%% initial case
build_2nd_stage(PrevLogTree = #log_tree{data = undefined, children = Children}) ->
  PrevLogTree#log_tree{children = lists:map(fun(Child) -> build_2nd_stage(Child) end, Children)};
%% intermediate cases
build_2nd_stage(PrevLogTree =
  #log_tree{end_parts = EndParts, commit_index_parts = CommIndexParts, children = Children}) ->
  case (EndParts == []) and (CommIndexParts == []) and (length(Children) == 1) of
    true -> % collapse this entry (do only collapse if there is a branch so no bubbling up of children)
      [Child] = Children,
      build_2nd_stage(Child);
    false -> % do not collapse and just recurse
      PrevLogTree#log_tree{children =
                           lists:map(fun(Child) -> build_2nd_stage(Child) end, Children)}
  end.

build_3rd_stage(PrevLogTree, State) ->
  build_3rd_stage_rec(PrevLogTree, State, maps:new(), 0).
build_3rd_stage_rec(#log_tree{commit_index_parts = CommIndexParts, children = Children, end_parts = EndParts},
    State = #state{part_to_state_map = PartStateMap}, MapProcCommIndex, DistanceFromRoot) ->
  MapProcCommIndex1 = lists:foldl(fun(Proc, MapProcCommIndexAcc) -> maps:put(Proc, DistanceFromRoot, MapProcCommIndexAcc) end,
            MapProcCommIndex, CommIndexParts),
  PartsInfo = lists:sort(lists:map(fun(Proc) ->
                          PartRecord = maps:get(Proc, PartStateMap),
                          VotedForLess = case PartRecord#per_part_state.voted_for of
                                           undefined -> not_given;
                                           Other ->
                                             OtherRecord = maps:get(Other, PartStateMap),
                                             OtherRecord#per_part_state.commit_index < PartRecord#per_part_state.commit_index
                                         end,
                          #per_part_abs_info{
                            role = PartRecord#per_part_state.state,
                            commit_index = maps:get(Proc, MapProcCommIndex1),
                            term = PartRecord#per_part_state.current_term,
                            voted_for_less = VotedForLess
                          }
                        end,
                        EndParts)),
  AbsChildren = lists:map(
    fun(Child) -> build_3rd_stage_rec(Child, State, MapProcCommIndex1, DistanceFromRoot + 1) end,
    Children),
  #abs_log_tree{part_info = PartsInfo, children = AbsChildren}.

build_4th_stage(AbsLogTree) ->
  AllLeaderTermsSet = get_all_leader_terms(AbsLogTree),
  AllLeaderTermsSorted = lists:sort(sets:to_list(AllLeaderTermsSet)),
  MapLeaderTermDummyTerm = maps:from_list(lists:zip(
    AllLeaderTermsSorted, lists:seq(1, length(AllLeaderTermsSorted))
  )),
  build_4th_stage_rec(AbsLogTree, MapLeaderTermDummyTerm).

build_4th_stage_rec(AbsLogTree = #abs_log_tree{part_info = PartInfo, children = Children}, MapLeaderTermDummyTerm) ->
  PartInfo1 = lists:map(
    fun(PerPartInfo = #per_part_abs_info{role = State, commit_index = CommIndex, term = CurrentTerm}) ->
      case State == leader of
        true -> PerPartInfo#per_part_abs_info{term = maps:get(CurrentTerm, MapLeaderTermDummyTerm)};
        false -> PerPartInfo#per_part_abs_info{term = undefined}
      end
    end,
    PartInfo),
  Children1 = lists:map(fun(Child) -> build_4th_stage(Child) end, Children),
  AbsLogTree#abs_log_tree{part_info = PartInfo1, children = Children1}.

%% temporary functions for sanity checks
check_stage_has_all_comm_and_end(Stage, AllParts) ->
  {EndParts, CommParts} = compute_endparts_and_commparts(Stage),
  AllPartsSet = sets:from_list(AllParts),
  case EndParts == AllPartsSet of
    true -> ok;
    false -> erlang:display("Obtained Stage with missing End part"),
      erlang:display(["Stage", Stage])
  end,
  case CommParts == AllPartsSet of
    true -> ok;
    false -> erlang:display("Obtained Stage with missing Comm part"),
      erlang:display(["Stage", Stage])
  end,
  ok.

compute_endparts_and_commparts(#log_tree{children = Children, end_parts = EndParts, commit_index_parts = CommParts}) ->
  lists:foldl(
    fun(Child, {EndPartsAcc, CommPartsAcc}) ->
      {ChildEndParts, ChildCommParts} = compute_endparts_and_commparts(Child),
      {sets:union(EndPartsAcc, ChildEndParts), sets:union(CommPartsAcc, ChildCommParts)}
    end,
    {sets:from_list(EndParts), sets:from_list(CommParts)},
    Children
  ).

get_all_leader_terms(AbsLogTree) ->
  ListProcInfo = get_all_proc_info_rec(AbsLogTree),
  erlang:display(["ListProcInfo", ListProcInfo]),
  TermAccFunc = fun(#per_part_abs_info{role = State, term = Term}, Acc) -> case State == leader of
                                               true -> sets:add_element(Term, Acc);
                                               false -> Acc
                                             end end,
  LeaderTermsList = lists:foldl(TermAccFunc, sets:new(), ListProcInfo),
  erlang:display(["LeadersTermsList", sets:to_list(LeaderTermsList)]),
  LeaderTermsList.

get_all_proc_info_rec(#abs_log_tree{children = Children, part_info = PartInfo}) ->
  ChildrenInfo = lists:append(lists:map(fun(Child) -> get_all_proc_info_rec(Child) end, Children)),
  lists:append(PartInfo, ChildrenInfo).
