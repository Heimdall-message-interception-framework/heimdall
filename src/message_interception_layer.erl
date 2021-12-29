%%%-------------------------------------------------------------------
%%% @author fms
%%% @copyright (C) 2021, <COMPANY>
%%% @doc
%%% @end
%%%-------------------------------------------------------------------
-module(message_interception_layer).

-include_lib("sched_event.hrl").

-behaviour(gen_server).

%% gen_server callback
-export([start/0, start_link/0, init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2,
  code_change/3]).
%% API for SUT
-export([register_with_name/4, deregister/3, msg_command/6, enable_timeout/4, disable_timeout/3, enable_timeout/5]).
%% API for scheduling engine
-export([no_op/1, exec_msg_command/4, exec_msg_command/7, duplicate_msg_command/4, alter_msg_command/5, drop_msg_command/4, fire_timeout/3, transient_crash/2, rejoin/2, permanent_crash/2]).
%% Getters
-export([get_commands_in_transit/1, get_timeouts/1, get_all_node_names/1, get_transient_crashed_nodes/1, get_permanent_crashed_nodes/1, get_name_for_pid/1]).

-record(state, {
  registered_nodes_pid = orddict:new() :: orddict:orddict(Name::atom(), pid()),
  registered_pid_nodes = orddict:new() :: orddict:orddict(pid(), Name::atom()),
  transient_crashed_nodes = sets:new() :: sets:set(atom()),
  permanent_crashed_nodes = sets:new() :: sets:set(atom()),
  map_commands_in_transit = orddict:new() :: orddict:orddict(FromTo::any(),
                              queue:queue({ID::any(), Module::atom(), Function::atom(), Args::list(any())})),
  list_commands_in_transit = [] :: [{ID::any(), From::pid(), To::pid(), Module::atom(), Function::atom(), ListArgs::list(any())}],
%%  enabled_timeouts = orddict:new() :: orddict:orddict(Proc::any(),
%%                                                      orddict:orddict({TimerRef::reference(), {Time::any(), Module::atom(), Function::atom(), ListArgs::list(any())}})),
%%  TODO: change to queue
  enabled_timeouts = [] :: [{TimerRef::reference(), ID::any(), Proc::any(), Time::any(), Module::atom(), Function::atom(), ListArgs::list(any())}],
  id_counter = 0 :: any()
}).

%%%===================================================================
%%% API
%%%===================================================================

%% FOR SUT

%% registration of processes
-spec register_with_name(pid(), nonempty_string(), pid(), _) -> any().
register_with_name(MIL, Name, Identifier, Kind) -> % Identifier can be PID or ...
  gen_server:call(MIL, {register, {Name, Identifier, Kind}}).
%% de-registration of processes
deregister(MIL, Name, Identifier) ->
  gen_server:call(MIL, {deregister, {Name, Identifier}}).

%% msg_commands
msg_command(MIL, From, {To, _Node}, Module, Fun, Args) ->
%%  TODO: this is a hack currently and does only work with one single nonode@... which is Node
  msg_command(MIL, From, To, Module, Fun, Args);
msg_command(MIL, From, To, Module, Fun, Args) ->
  gen_server:call(MIL, {msg_cmd, {From, To, Module, Fun, Args}}).

%% timeouts
enable_timeout(MIL, Time, Dest, Msg) ->
  enable_timeout(MIL, Time, Dest, Msg, undefined).
%%
enable_timeout(MIL, Time, Dest, Msg, _Options) ->
%%  we assume that processes do only send timeouts to themselves and ignore Options
  TimerRef = gen_server:call(MIL, {enable_to, {Time, Dest, Dest, erlang, send, [{mil_timeout, Msg}]}}),
%%  erlang:display(["enable_to", TimerRef]),
  TimerRef.
%%
disable_timeout(MIL, Proc, TimerRef) ->
%%  TODO: currently, we do not really check if the timeout to disable is actually enabled,
%% need to rearrange calls to API for this and ensure that disable is closer to enable and iff not fired
%%  erlang:display(["disable_to", TimerRef]),
  Result = gen_server:call(MIL, {disable_to, {Proc, TimerRef}}),
  Result.

%% FOR SCHEDULING ENGINE
%%
no_op(_MIL) ->
  ok.
%% deprecated, use the one with 4 parameters
exec_msg_command(MIL, ID, From, To, _Module, _Fun, _Args) ->
  exec_msg_command(MIL, ID, From, To).
%%
exec_msg_command(MIL, ID, From, To) ->
  gen_server:call(MIL, {exec_msg_cmd, {ID, From, To}}).
%%
duplicate_msg_command(MIL, ID, From, To) ->
  gen_server:call(MIL, {duplicate, {ID, From, To}}).
%%
alter_msg_command(MIL, Id, From, To, NewArgs) ->
  gen_server:call(MIL, {send_altered, {Id, From, To, NewArgs}}).
%%
drop_msg_command(MIL, Id, From, To) ->
  gen_server:call(MIL, {drop, {Id, From, To}}).
%%
fire_timeout(MIL, Proc, TimerRef) ->
  gen_server:call(MIL, {fire_to, {Proc, TimerRef}}).
%%
transient_crash(MIL, Name) ->
  ok = gen_server:call(MIL, {crash_trans, {Name}}).
%%
permanent_crash(MIL, Name) ->
  gen_server:call(MIL, {crash_perm, {Name}}).
%%
rejoin(MIL, Name) ->
  gen_server:call(MIL, {rejoin, {Name}}).

%% GETTER
%%
-spec get_commands_in_transit(pid()) -> [{ID::any(), From::pid(), To::pid(), Module::atom(), Function::atom(), ListArgs::list(any())}].
get_commands_in_transit(MIL) ->
  gen_server:call(MIL, {get_commands}).
%%
-spec get_timeouts(pid()) -> [{TimerRef::reference(), ID::any(), Proc::any(), Time::any(), Module::atom(), Function::atom(), ListArgs::list(any())}].
get_timeouts(MIL) ->
  gen_server:call(MIL, {get_timeouts}).
%%
get_all_node_names(MIL) ->
  gen_server:call(MIL, {get_all_node_names}).
%%
get_name_for_pid(Pid) ->
  [{_, Name}] = ets:lookup(pid_name_table, Pid),
  Name.
%%
-spec get_transient_crashed_nodes(pid()) -> sets:set().
get_transient_crashed_nodes(MIL) ->
  gen_server:call(MIL, {get_transient_crashed_nodes}).
%%
get_permanent_crashed_nodes(MIL) ->
  gen_server:call(MIL, {get_permanent_crashed_nodes}).


%%%===================================================================
%%% Spawning and gen_server implementation
%%%===================================================================

-spec(start() ->
  {ok, Pid :: pid()} | ignore | {error, Reason :: term()}).
start() ->
  gen_server:start({global,mil}, ?MODULE, [], []).

start_link() ->
  gen_server:start_link(?MODULE, [], []).

-spec(init(Args :: term()) ->
  {ok, State :: #state{}} | {ok, State :: #state{}, timeout() | hibernate} |
  {stop, Reason :: term()} | ignore).
init([]) ->
  case ets:info(pid_name_table) of
    undefined -> ets:new(pid_name_table, [named_table, {read_concurrency, true}, public]);
    _ -> ok
  end,
  {ok, #state{}}.

-spec handle_call
  ({register, {NodeName::nonempty_string(), NodePid::atom(), _}}, {pid(),_}, #state{}) -> {reply, ok, #state{}};
  ({get_commands}, {pid(), _}, #state{}) -> {reply, [{ID::any(), From::pid(), To::pid(), Module::atom(), Function::atom(), ListArgs::list(any())}], #state{}}.
%%
handle_call({get_commands}, _From, State = #state{}) ->
  {reply, State#state.list_commands_in_transit, State};
handle_call({enable_to, {Time, ProcPid, ProcPid, Module, Fun, [{mil_timeout, MsgContent}]}}, _From,
    State = #state{})
  when not is_tuple(ProcPid)->
  TimerRef = make_ref(),
  Args = [ProcPid, {mil_timeout, TimerRef, MsgContent}],
  Proc = pid_to_node(State, ProcPid),
  Bool_crashed = check_if_crashed(State, Proc) or check_if_crashed(State, Proc),
  case Bool_crashed of
    true ->
      SchedEvent = #sched_event{what = enable_to_crsh, id = State#state.id_counter,
        from = Proc, to = Proc, mod = Module, func = Fun, args = Args, timerref = TimerRef},
      msg_interception_helpers:submit_sched_event(SchedEvent),
      NextID = State#state.id_counter + 1,
      {reply, TimerRef, State#state{id_counter = NextID}};  % if crashed, do also not let whitelisted trough
    _ ->
%%      OrddictToUpdate = orddict:fetch(Proc, State#state.enabled_timeouts),
%%      UpdatedOrddict = orddict:append(TimerRef, {Time, Module, Fun, Args}, OrddictToUpdate),
%%      UpdatedEnabledTimeouts = orddict:store(Proc, UpdatedOrddict, State#state.enabled_timeouts),
      ListTimeouts1 = [ {TimerRef, State#state.id_counter, Proc, Time, Module, Fun, Args} | State#state.enabled_timeouts],
      SchedEvent = #sched_event{what = enable_to, id = State#state.id_counter,
        from = Proc, to = Proc, mod = Module, func = Fun, args = Args, timerref = TimerRef},
      msg_interception_helpers:submit_sched_event(SchedEvent),
      NextID = State#state.id_counter + 1,
      {reply, TimerRef, State#state{id_counter = NextID, enabled_timeouts = ListTimeouts1}}
  end;
%%
handle_call({disable_to, {ProcPid, TimerRef}}, _From, State = #state{}) ->
  Proc = pid_to_node(State, ProcPid),
  case find_timeout_and_get_updated_ones(State, TimerRef) of
    {found, {_TimeoutValue, NewEnabledTimeouts}} ->
      SchedEvent = #sched_event{what = disable_to, id = State#state.id_counter, timerref = TimerRef,
        from = Proc, to = Proc},
      NextId = State#state.id_counter + 1,
      msg_interception_helpers:submit_sched_event(SchedEvent),
      {reply, true, State#state{enabled_timeouts = NewEnabledTimeouts, id_counter = NextId}};
    {notfound, _} ->
      {reply, false, State}
  end;
%%
handle_call({fire_to, {Proc, TimerRef}}, _From, State = #state{}) ->
  case find_timeout_and_get_updated_ones(State, TimerRef) of
    {found, {TimeoutValue, NewEnabledTimeouts}} ->
      {TimerRef, _ID, Proc, _Time, Mod, Func, Args} = TimeoutValue,
      erlang:apply(Mod, Func, Args),
      SchedEvent = #sched_event{what = fire_to, id = State#state.id_counter,
        from = Proc, to = Proc, timerref = TimerRef},
      NextId = State#state.id_counter + 1,
      msg_interception_helpers:submit_sched_event(SchedEvent),
      {reply, true, State#state{enabled_timeouts = NewEnabledTimeouts, id_counter = NextId}};
    {notfound, _} ->
      erlang:throw("tried to fire disabled timeout")
  end;
%%
handle_call({get_commands}, _From, State = #state{}) ->
  {reply, State#state.list_commands_in_transit, State};
%%
handle_call({get_transient_crashed_nodes}, _From, #state{transient_crashed_nodes = TransientCrashedNodes} = State) ->
  {reply, TransientCrashedNodes, State};
%%
handle_call({get_permanent_crashed_nodes}, _From, #state{permanent_crashed_nodes = PermanentCrashedNodes} = State) ->
  {reply, PermanentCrashedNodes, State};
%%
handle_call({get_all_node_names}, _From, #state{} = State) ->
  NodeNames = orddict:to_list(State#state.registered_nodes_pid),
  % NodeNames = get_all_node_names_from_state(State),
  {reply, NodeNames, State};
%%
handle_call({get_timeouts}, _From, State = #state{}) ->
  {reply, State#state.enabled_timeouts, State};
% -spec(handle_cast(Request :: term(), State :: #state{}) ->
%   {noreply, NewState :: #state{}} |
%   {noreply, NewState :: #state{}, timeout() | hibernate} |
%   {stop, Reason :: term(), NewState :: #state{}}).
%%
handle_call({register, {NodeName, NodePid, NodeClass}}, _From, State) ->
  {NodeNameAtom, NodeNameString} = case is_atom(NodeName) of
    true -> {NodeName, atom_to_list(NodeName)};
    false -> {list_to_atom(NodeName), NodeName} end,
  ets:insert(pid_name_table, {NodePid, NodeNameString}),
  NewRegisteredNodesPid = orddict:store(NodeNameAtom, NodePid, State#state.registered_nodes_pid),
  NewRegisteredPidNodes = orddict:store(NodePid, NodeNameAtom, State#state.registered_pid_nodes),
  AllOtherNames = get_all_node_names_from_state(State),
  CmdListNewQueues = [{{Other, NodeNameAtom}, queue:new()} || Other <- AllOtherNames] ++
                  [{{NodeNameAtom, Other}, queue:new()} || Other <- AllOtherNames],
  CmdOrddictNewQueues = orddict:from_list(CmdListNewQueues),
  Fun = fun({_, _}, _, _) -> undefined end,
  NewCommandStore = orddict:merge(Fun, State#state.map_commands_in_transit, CmdOrddictNewQueues),
  SchedEvent = #sched_event{what = reg_node, id = State#state.id_counter, name = NodeName, class = NodeClass},
  NextId = State#state.id_counter + 1,
  msg_interception_helpers:submit_sched_event(SchedEvent),
  {reply, ok, State#state{registered_nodes_pid = NewRegisteredNodesPid,
                        registered_pid_nodes = NewRegisteredPidNodes,
                        map_commands_in_transit = NewCommandStore,
                        id_counter = NextId}};
handle_call({deregister, {NodeName, NodePid}}, _From, State) ->
  ets:delete(pid_name_table, NodePid),
  NewRegisteredNodesPid = orddict:erase(NodeName, State#state.registered_nodes_pid),
  NewRegisteredPidNodes = orddict:erase(NodePid, State#state.registered_pid_nodes),
%%  TODO: remove from CommandStore
%%  AllOtherNames = get_all_node_names_from_state(State),
%%  CmdListNewQueues = [{{Other, NodeName}, queue:new()} || Other <- AllOtherNames] ++
%%    [{{NodeName, Other}, queue:new()} || Other <- AllOtherNames],
%%  CmdOrddictNewQueues = orddict:from_list(CmdListNewQueues),
%%  Fun = fun({_, _}, _, _) -> undefined end,
%%  NewCommandStore = orddict:merge(Fun, State#state.map_commands_in_transit, CmdOrddictNewQueues),
%%  TODO: add sched_event about de-registeration
%%  SchedEvent = #sched_event{what = reg_node, id = State#state.id_counter, name = NodeName},
%%  NextId = State#state.id_counter + 1,
%%  msg_interception_helpers:submit_sched_event(SchedEvent),
  {reply, ok, State#state{registered_nodes_pid = NewRegisteredNodesPid,
    registered_pid_nodes = NewRegisteredPidNodes
%%    map_commands_in_transit = NewCommandStore,
%%    id_counter = NextId
 }};
handle_call({msg_cmd, {FromPid, ToPid, Module, Fun, Args}}, _From, State = #state{})
  when not is_tuple(ToPid)->
  From = pid_to_node(State, FromPid),
  To = case is_pid(ToPid) of
         true -> pid_to_node(State, ToPid);
         _ -> ToPid
       end,
  Bool_crashed = check_if_crashed(State, To) or check_if_crashed(State, From),
%%  Bool_whitelisted = check_if_whitelisted(Module, Fun, Args),
  if
    Bool_crashed ->
      SchedEvent = #sched_event{what = cmd_rcv_crsh, id = State#state.id_counter,
        from = From, to = To, mod = Module, func = Fun, args = Args},
      msg_interception_helpers:submit_sched_event(SchedEvent),
      NextID = State#state.id_counter + 1,
      {reply, ok, State#state{id_counter = NextID}};  % if crashed, do also not let whitelisted trough
%%    Bool_whitelisted -> do_exec_cmd(Module, Fun, Args),
%%      {noreply, State};
    true ->
      QueueToUpdate = orddict:fetch({From, To}, State#state.map_commands_in_transit),
      UpdatedQueue = queue:in({State#state.id_counter, Module, Fun, Args}, QueueToUpdate),
      UpdatedCommandsInTransit = orddict:store({From, To}, UpdatedQueue, State#state.map_commands_in_transit),
%%      UpdatedListCommandsInTransit = State#state.list_commands_in_transit ++
%%        [{State#state.id_counter, From, To, Module, Fun, Args}],
      UpdatedListCommandsInTransit =
        [ {State#state.id_counter, From, To, Module, Fun, Args} | State#state.list_commands_in_transit ],
      SchedEvent = #sched_event{what = cmd_rcv, id = State#state.id_counter,
        from = From, to = To, mod = Module, func = Fun, args = Args},
      msg_interception_helpers:submit_sched_event(SchedEvent),
      NextID = State#state.id_counter + 1,
      {reply, ok, State#state{map_commands_in_transit = UpdatedCommandsInTransit,
        list_commands_in_transit = UpdatedListCommandsInTransit,
        id_counter = NextID}}
  end;
%%
handle_call({exec_msg_cmd, {Id, From, To}}, _From, State = #state{}) ->
  % io:format("[~p] exec_msg_cmd {~p, ~p, ~p}", [?MODULE, Id, From, To]),
  {Mod, Func, Args, Skipped, NewCommandStore} = find_cmd_and_get_updated_commands_in_transit(State, Id, From, To),
  do_exec_cmd(Mod, Func, Args),
  SchedEvent = #sched_event{what = exec_msg_cmd, id = Id,
    from = From, to = To, skipped = Skipped,
    mod = Mod, func = Func, args = Args},
  msg_interception_helpers:submit_sched_event(SchedEvent),
  NewListCommand = lists:filter(fun({Idx, _, _, _, _, _}) -> Idx /= Id end, State#state.list_commands_in_transit),
  {reply, ok, State#state{map_commands_in_transit = NewCommandStore, list_commands_in_transit = NewListCommand}};
%%
handle_call({duplicate, {Id, From, To}}, _From, State = #state{}) ->
  % io:format("[~p] duplicate {~p, ~p, ~p}", [?MODULE, Id, From, To]),
  {Mod, Func, Args, Skipped, _NewCommandStore} =
      find_cmd_and_get_updated_commands_in_transit(State, Id, From, To),
  do_exec_cmd(Mod, Func, Args),
  SchedEvent = #sched_event{what = duplicat, id = Id, from = From, to = To,
                            mod = Mod, func = Func, args = Args, skipped = Skipped},
  msg_interception_helpers:submit_sched_event(SchedEvent),
%%  we do not update state since we duplicate
  {reply, ok, State};
%%
handle_call({send_altered, {Id, From, To, NewArgs}}, _From, State = #state{}) ->
  % io:format("[~p] send_altered {~p, ~p, ~p}", [?MODULE, Id, From, To]),
  {Mod, Func, _Args, Skipped, NewCommandStore} =
    find_cmd_and_get_updated_commands_in_transit(State, Id, From, To),
  do_exec_cmd(Mod, Func, NewArgs),
  SchedEvent = #sched_event{what = snd_altr, id = Id, from = From, to = To,
    mod = Mod, func = Func, args = NewArgs, skipped = Skipped},
  msg_interception_helpers:submit_sched_event(SchedEvent),
  NewListCommand = lists:filter(fun({Idx, _, _, _, _, _}) -> Idx /= Id end, State#state.list_commands_in_transit),
  {reply, ok, State#state{map_commands_in_transit = NewCommandStore, list_commands_in_transit = NewListCommand}};
%%
handle_call({drop, {Id, From, To}}, _From, State = #state{}) ->
  % io:format("[~p] drop {~p, ~p, ~p}", [?MODULE, Id, From, To]),
  {Mod, Func, Args, Skipped, NewCommandStore} =
    find_cmd_and_get_updated_commands_in_transit(State, Id, From, To),
  SchedEvent = #sched_event{what = drop_msg, id = Id, from = From, to = To, mod = Mod, func = Func, args = Args, skipped = Skipped},
  msg_interception_helpers:submit_sched_event(SchedEvent),
  NewListCommand = lists:filter(fun({Idx, _, _, _, _, _}) -> Idx /= Id end, State#state.list_commands_in_transit),
  {reply, ok, State#state{map_commands_in_transit = NewCommandStore, list_commands_in_transit = NewListCommand}};
%%
handle_call({crash_trans, {NodeName}}, _From, State = #state{}) ->
  % io:format("[~p] crash_trans. commands in transit: ~p", [?MODULE, State#state.map_commands_in_transit]),
  UpdatedCrashTrans = sets:add_element(NodeName, State#state.transient_crashed_nodes),
  ListQueuesToEmpty = [{Other, NodeName} || Other <- get_all_node_names_from_state(State), Other /= NodeName],
  NewCommandsStore = lists:foldl(fun({From, To}, SoFar) -> orddict:store({From, To}, queue:new(), SoFar) end,
              State#state.map_commands_in_transit,
              ListQueuesToEmpty),
  % io:format("[~p] crash_trans. new commands in transit: ~p", [?MODULE, NewCommandsStore]),
  SchedEvent = #sched_event{what = trns_crs, id = State#state.id_counter, name = NodeName},
  NextId = State#state.id_counter + 1,
  msg_interception_helpers:submit_sched_event(SchedEvent),
  % TODO: is this correct?
  % I think the condition would need to be (not [From =/= NodeName and To == NodeName])
  % since we do only remove messages going to the crashing process, not the ones from it (has already been sent)
  NewListCommand = lists:filter(fun({_, From, To, _, _, _}) -> (From == NodeName) or (To =/= NodeName) end, State#state.list_commands_in_transit),
  {reply, ok, State#state{transient_crashed_nodes = UpdatedCrashTrans,
                        map_commands_in_transit = NewCommandsStore,
                        list_commands_in_transit = NewListCommand,
                        id_counter = NextId}};
%%
handle_call({rejoin, {NodeName}}, _From, State = #state{}) ->
%%  for transient crashes only
  UpdatedCrashTrans = sets:del_element(NodeName, State#state.transient_crashed_nodes),
  SchedEvent = #sched_event{what = rejoin, id = State#state.id_counter, name = NodeName},
  NextId = State#state.id_counter + 1,
  msg_interception_helpers:submit_sched_event(SchedEvent),
  {reply, ok, State#state{transient_crashed_nodes = UpdatedCrashTrans, id_counter = NextId}};
handle_call({crash_perm, {NodeName}}, _From, State = #state{}) ->
%%  we keep the outgoing channels since these are messages that were sent before (still scheduable)
  UpdatedCrashPerm = sets:add_element(NodeName, State#state.permanent_crashed_nodes),
  ListQueuesToDelete = [{Other, NodeName} || Other <- get_all_node_names_from_state(State), Other /= NodeName],
  NewCommandStore = lists:foldl(fun({From, To}, SoFar) -> orddict:erase({From, To}, SoFar) end,
    State#state.map_commands_in_transit,
    ListQueuesToDelete),
  SchedEvent = #sched_event{what = perm_crs, id = State#state.id_counter, name = NodeName},
  NextId = State#state.id_counter + 1,
  msg_interception_helpers:submit_sched_event(SchedEvent),
  {reply, ok, State#state{permanent_crashed_nodes = UpdatedCrashPerm,
                        map_commands_in_transit = NewCommandStore,
                        id_counter = NextId}};
handle_call(_Request, _From, State) ->
  erlang:throw(["unhandled call", _Request]),
  {reply, ok, State}.
%%
handle_cast(Msg, State) ->
  io:format("[cb] received unhandled cast: ~p~n", [Msg]),
  {noreply, State}.


-spec(handle_info(Info :: timeout() | term(), State :: #state{}) ->
  {noreply, NewState :: #state{}} |
  {noreply, NewState :: #state{}, timeout() | hibernate} |
  {stop, Reason :: term(), NewState :: #state{}}).
handle_info(_Info, State = #state{}) ->
  {noreply, State}.

terminate(Reason, _State = #state{}) ->
  io:format("[MIL] Terminating. Reason: ~p~n", [Reason]),
  ok.

code_change(_OldVsn, State = #state{}, _Extra) ->
  {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

%%node_to_pid(State, Node) ->
%%  {ok, Pid} = orddict:find(Node, State#state.registered_nodes_pid),
%%  Pid.

pid_to_node(State, Pid) ->
  case orddict:find(Pid, State#state.registered_pid_nodes) of
    {ok, Node} -> Node;
    _ -> NameInTable = ets:lookup(pid_name_table, Pid),
      erlang:display(["NameInTable", NameInTable]),
      erlang:error([pid_not_registered, Pid])
  end.

check_if_crashed(State, To) ->
  sets:is_element(To, State#state.transient_crashed_nodes) or sets:is_element(To, State#state.permanent_crashed_nodes).

get_all_node_names_from_state(State) ->
  orddict:fetch_keys(State#state.registered_nodes_pid).

find_cmd_and_get_updated_commands_in_transit(State, Id, From, To) ->
  QueueToSearch = orddict:fetch({From, To}, State#state.map_commands_in_transit),
  {Mod, Func, Args, Skipped, UpdatedQueue} = find_cmd_id_in_queue(QueueToSearch, Id),
  NewCommandStore = orddict:store({From, To}, UpdatedQueue, State#state.map_commands_in_transit),
  {Mod, Func, Args, Skipped, NewCommandStore}.

do_exec_cmd(Mod, Func, Args) ->
  erlang:apply(Mod, Func, Args).

find_cmd_id_in_queue(QueueToSearch, Id) ->
  find_cmd_id_in_queue([], QueueToSearch, Id).

find_cmd_id_in_queue(SkippedList, TailQueueToSearch, Id) ->
  % io:format("[~p] trying to find cmd_id ~p in queue ~p", [?MODULE, Id, TailQueueToSearch]),
  Result = queue:out(TailQueueToSearch),
  {{value, {CurrentId, Mod, Func, Args}}, NewTailQueueToSearch} = Result,
  case CurrentId == Id  of
    true -> ReversedSkipped = lists:reverse(SkippedList),
      {Mod, Func, Args, ReversedSkipped, queue:join(queue:from_list(ReversedSkipped), NewTailQueueToSearch)};
    false -> find_cmd_id_in_queue([{CurrentId, Mod, Func, Args} | SkippedList], NewTailQueueToSearch, Id)
  end.

find_timeout_and_get_updated_ones(#state{enabled_timeouts = EnabledTimeouts}, TimerRef) ->
  FilterFunction = fun({TimerRef1,_ , _, _, _, _, _}) -> TimerRef == TimerRef1  end,
  {RetrievedTimeoutList, NewEnabledTimeouts} = lists:partition(FilterFunction, EnabledTimeouts),
  case RetrievedTimeoutList of
    [RetrievedTimeout] -> {found, {RetrievedTimeout, NewEnabledTimeouts}};
    [] -> {notfound, undefined};
    _ -> erlang:throw("multipled timeouts with the same timerref")
  end.