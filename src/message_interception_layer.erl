%%%-------------------------------------------------------------------
%%% @author fms
%%% @copyright (C) 2021, <COMPANY>
%%% @doc
%%% @end
%%%-------------------------------------------------------------------
-module(message_interception_layer).

-include_lib("sched_event.hrl").
-include_lib("kernel/include/logger.hrl").
-behaviour(gen_server).

%% gen_server callback
-export([start/0, start_link/0, init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2,
  code_change/3]).
%% API for SUT
-export([register_with_name/3, deregister/2, msg_command/5, enable_timeout/3, disable_timeout/2, enable_timeout/4]).
%% API for scheduling engine
-export([no_op/0, exec_msg_command/3, exec_msg_command/6, duplicate_msg_command/3, alter_msg_command/4, drop_msg_command/3, fire_timeout/2, transient_crash/1, rejoin/1, permanent_crash/1]).
%% Getters
-export([get_commands_in_transit/0, get_timeouts/0, get_transient_crashed_nodes/0, get_permanent_crashed_nodes/0, get_name_for_pid/1, get_all_node_pids/0]).

-type timerref() :: reference() | false.
-type mil_timeout() :: any().
-type command() :: any().

-record(state, {
  registered_node_pids = sets:new() :: sets:set(pid()),
  transient_crashed_nodes = sets:new() :: sets:set(pid()),
  permanent_crashed_nodes = sets:new() :: sets:set(pid()),
  map_commands_in_transit = orddict:new() :: orddict:orddict(FromTo::{pid(), pid()},
                              queue:queue({ID::number(), Module::atom(), Function::atom(), Args::list(any())})),
  list_commands_in_transit = [] :: [{ID::number(), From::pid(), To::pid(), Module::atom(), Function::atom(), ListArgs::list(any())}],
%%  enabled_timeouts = orddict:new() :: orddict:orddict(Proc::any(),
%%                                                      orddict:orddict({TimerRef::reference(), {Time::any(), Module::atom(), Function::atom(), ListArgs::list(any())}})),
%%  TODO: change to queue
  enabled_timeouts = [] :: [{TimerRef::reference(), ID::number(), Proc::pid(), Time::any(), Module::atom(), Function::atom(), ListArgs::list(any())}],
  id_counter = 0 :: number()
}).

%%%===================================================================
%%% API
%%%===================================================================

%% FOR SUT

%% registration of processes
-spec register_with_name(nonempty_string() | atom(), pid(), _) -> ok.
register_with_name(Name, Identifier, Kind) when is_atom(Name) -> % Identifier can be PID or ...
  logger:warning("[~p] got registration with atom ~p. Turning into string.", [?MODULE, Name]),
  NameString = atom_to_list(Name),
  gen_server:call(?MODULE, {register, {NameString, Identifier, Kind}});
register_with_name(Name, Identifier, Kind) when is_list(Name) -> % Identifier can be PID or ...
  logger:debug("[~p] registering ~p with pid ~p", [?MODULE, Name, Identifier]),
  Result = gen_server:call(?MODULE, {register, {Name, Identifier, Kind}}),
  logger:debug("[~p] table is now: ~p", [?MODULE, ets:tab2list(pid_name_table)]),
  Result.
%% de-registration of processes
-spec deregister(nonempty_string(), pid()) -> any().
deregister(Name, Identifier) ->
  gen_server:call(?MODULE, {deregister, {Name, Identifier}}).

%% msg_commands
% -spec msg_command(pid(), pid(), gen_mi_statem:server_ref(), atom(), atom(), [any()]) -> ok.
-spec msg_command(pid(), pid() | gen_mi_statem:server_ref(), atom(), atom(), [any()]) -> ok.
msg_command(From, {To, _Node}, Module, Fun, Args) ->
%%  TODO: this is a hack currently and does only work with one single nonode@... which is Node
  msg_command(From, To, Module, Fun, Args);
msg_command(From, To, Module, Fun, Args) ->
  gen_server:call(?MODULE, {msg_cmd, {From, To, Module, Fun, Args}}).

%% timeouts
-spec enable_timeout(_, pid(), _) -> timerref().
enable_timeout(Time, Dest, Msg) ->
  enable_timeout(Time, Dest, Msg, undefined).
%%
-spec enable_timeout(_, pid(), _, _) -> timerref().
enable_timeout(Time, Dest, Msg, _Options) ->
%%  we assume that processes do only send timeouts to themselves and ignore Options
  TimerRef = gen_server:call(?MODULE, {enable_to, {Time, Dest, Dest, erlang, send, [{mil_timeout, Msg}]}}),
%%  erlang:display(["enable_to", TimerRef]),
  TimerRef.
%%
-spec disable_timeout(pid(), timerref()) -> timerref().
disable_timeout(Proc, TimerRef) ->
%%  TODO: currently, we do not really check if the timeout to disable is actually enabled,
%% need to rearrange calls to API for this and ensure that disable is closer to enable and iff not fired
%%  erlang:display(["disable_to", TimerRef]),
  Result = gen_server:call(?MODULE, {disable_to, {Proc, TimerRef}}),
  Result.

%% FOR SCHEDULING ENGINE
%%
-spec no_op() -> 'ok'.
no_op() ->
  ok.
%% deprecated, use the one with 4 parameters
-spec exec_msg_command(number(), pid(), pid(), _, _, _) -> ok.
exec_msg_command(ID, From, To, _Module, _Fun, _Args) ->
  exec_msg_command(ID, From, To).
%%
-spec exec_msg_command(number(), pid(), pid()) -> ok.
exec_msg_command(ID, From, To) ->
  gen_server:call(?MODULE, {exec_msg_cmd, {ID, From, To}}).
%%
-spec duplicate_msg_command(number(), pid(), pid()) -> ok.
duplicate_msg_command(ID, From, To) ->
  gen_server:call(?MODULE, {duplicate, {ID, From, To}}).
%%
-spec alter_msg_command(number(), pid(), pid(), [any()]) -> ok.
alter_msg_command(Id, From, To, NewArgs) ->
  gen_server:call(?MODULE, {send_altered, {Id, From, To, NewArgs}}).
%%
-spec drop_msg_command(number(), pid(), pid()) -> ok.
drop_msg_command(Id, From, To) ->
  gen_server:call(?MODULE, {drop, {Id, From, To}}).
%%
-spec fire_timeout(atom(), timerref()) -> any().
fire_timeout(Proc, TimerRef) ->
  gen_server:call(?MODULE, {fire_to, {Proc, TimerRef}}).
%%
-spec transient_crash(pid()) -> 'ok'.
transient_crash(Name) ->
  ok = gen_server:call(?MODULE, {crash_trans, {Name}}).
%%
-spec permanent_crash(atom()) -> ok.
permanent_crash(Name) ->
  gen_server:call(?MODULE, {crash_perm, {Name}}).
%%
-spec rejoin(atom()) -> ok.
rejoin(Name) ->
  gen_server:call(?MODULE, {rejoin, {Name}}).

%% GETTER
%%
-spec get_commands_in_transit() -> [{ID::any(), From::pid(), To::pid(), Module::atom(), Function::atom(), ListArgs::list(any())}].
get_commands_in_transit() ->
  gen_server:call(?MODULE, {get_commands}).
%%
-spec get_timeouts() -> [{TimerRef::reference(), ID::any(), Proc::any(), Time::any(), Module::atom(), Function::atom(), ListArgs::list(any())}].
get_timeouts() ->
  gen_server:call(?MODULE, {get_timeouts}).
%%
-spec get_all_node_pids() -> [{atom(), pid()}].
get_all_node_pids() ->
  gen_server:call(?MODULE, {get_all_node_pids}).
%%
-spec get_name_for_pid(pid()) -> nonempty_string().
get_name_for_pid(Pid) ->
  [{_, Name}] = ets:lookup(pid_name_table, Pid),
  Name.
%%
-spec get_transient_crashed_nodes() -> sets:set(atom()).
get_transient_crashed_nodes() ->
  gen_server:call(?MODULE, {get_transient_crashed_nodes}).
%%
-spec get_permanent_crashed_nodes() -> sets:set(atom()).
get_permanent_crashed_nodes() ->
  gen_server:call(?MODULE, {get_permanent_crashed_nodes}).


%%%===================================================================
%%% Spawning and gen_server implementation
%%%===================================================================

-spec(start() ->
  {ok, Pid :: pid()} | ignore | {error, Reason :: term()}).
start() ->
  gen_server:start({local, ?MODULE}, ?MODULE, [], []).

-spec start_link() -> 'ignore' | {'error', _} | {'ok', pid() | {pid(), reference()}}.
start_link() ->
  gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

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
  ({register, {NodeName::nonempty_string(), NodePid::pid(), _}}, {pid(),_}, #state{}) -> {reply, ok, #state{}};
  ({get_commands}, _, #state{}) -> {reply, [{ID::any(), From::pid(), To::pid(), Module::atom(), Function::atom(), ListArgs::list(any())}], #state{}};
  ({enable_to, {Time::_, ProcPid::pid(), ProcPid::pid(), Module::atom(), Fun::atom, Args::[any()]}}, _, #state{}) -> {reply, timerref(), #state{}};
  ({msg_cmd, {FromPid :: pid(), ToPid :: pid(), Module :: atom(), Fun :: atom(), Args :: [any()]}}, _, #state{}) -> {reply, ok, #state{}}.
%%
handle_call({enable_to, {Time, ProcPid, ProcPid, Module, Fun, [{mil_timeout, MsgContent}]}}, _From,
    State = #state{})
  when not is_tuple(ProcPid)->
  TimerRef = make_ref(),
  Args = [ProcPid, {mil_timeout, TimerRef, MsgContent}],
  Bool_crashed = check_if_crashed(State, ProcPid),
  case Bool_crashed of
    true ->
      SchedEvent = #sched_event{what = enable_to_crsh, id = State#state.id_counter,
        from = ProcPid, to = ProcPid, mod = Module, func = Fun, args = Args, timerref = TimerRef},
      msg_interception_helpers:submit_sched_event(SchedEvent),
      NextID = State#state.id_counter + 1,
      {reply, TimerRef, State#state{id_counter = NextID}};  % if crashed, do also not let whitelisted trough
    _ ->
%%      OrddictToUpdate = orddict:fetch(Proc, State#state.enabled_timeouts),
%%      UpdatedOrddict = orddict:append(TimerRef, {Time, Module, Fun, Args}, OrddictToUpdate),
%%      UpdatedEnabledTimeouts = orddict:store(Proc, UpdatedOrddict, State#state.enabled_timeouts),
      ListTimeouts1 = [ {TimerRef, State#state.id_counter, ProcPid, Time, Module, Fun, Args} | State#state.enabled_timeouts],
      SchedEvent = #sched_event{what = enable_to, id = State#state.id_counter,
        from = ProcPid, to = ProcPid, mod = Module, func = Fun, args = Args, timerref = TimerRef},
      msg_interception_helpers:submit_sched_event(SchedEvent),
      NextID = State#state.id_counter + 1,
      {reply, TimerRef, State#state{id_counter = NextID, enabled_timeouts = ListTimeouts1}}
  end;
%%
handle_call({disable_to, {ProcPid, TimerRef}}, _From, State = #state{}) ->
  case find_timeout_and_get_updated_ones(State, TimerRef) of
    {found, {_TimeoutValue, NewEnabledTimeouts}} ->
      SchedEvent = #sched_event{what = disable_to, id = State#state.id_counter, timerref = TimerRef,
        from = ProcPid, to = ProcPid},
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
handle_call({get_transient_crashed_nodes}, _From, #state{transient_crashed_nodes = TransientCrashedNodes} = State) ->
  {reply, TransientCrashedNodes, State};
%%
handle_call({get_permanent_crashed_nodes}, _From, #state{permanent_crashed_nodes = PermanentCrashedNodes} = State) ->
  {reply, PermanentCrashedNodes, State};
%%
handle_call({get_all_node_pids}, _From, #state{} = State) ->
  NodeNames = sets:to_list(State#state.registered_node_pids),
  % NodeNames = get_all_node_pids_from_state(State),
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
  ets:insert(pid_name_table, {NodePid, NodeName}),
  NewRegisteredNodesPid = sets:add_element(NodePid, State#state.registered_node_pids),
  AllOtherPidsList = get_all_node_pids_from_state(State),
  CmdListNewQueues = [{{Other, NodePid}, queue:new()} || Other <- AllOtherPidsList] ++
                  [{{NodePid, Other}, queue:new()} || Other <- AllOtherPidsList],
  CmdOrddictNewQueues = orddict:from_list(CmdListNewQueues),
  Fun = fun({_, _}, _, _) -> undefined end,
  NewCommandStore = orddict:merge(Fun, State#state.map_commands_in_transit, CmdOrddictNewQueues),
  SchedEvent = #sched_event{what = reg_node, id = State#state.id_counter, name = NodeName, class = NodeClass},
  NextId = State#state.id_counter + 1,
  msg_interception_helpers:submit_sched_event(SchedEvent),
  {reply, ok, State#state{registered_node_pids = NewRegisteredNodesPid,
                        map_commands_in_transit = NewCommandStore,
                        id_counter = NextId}};
handle_call({deregister, {_NodeName, NodePid}}, _From, State) ->
  ets:delete(pid_name_table, NodePid),
  NewRegisteredPidNodes = sets:del_element(NodePid, State#state.registered_node_pids),
%%  TODO: remove from CommandStore
%%  AllOtherNames = get_all_node_pids_from_state(State),
%%  CmdListNewQueues = [{{Other, NodeName}, queue:new()} || Other <- AllOtherNames] ++
%%    [{{NodeName, Other}, queue:new()} || Other <- AllOtherNames],
%%  CmdOrddictNewQueues = orddict:from_list(CmdListNewQueues),
%%  Fun = fun({_, _}, _, _) -> undefined end,
%%  NewCommandStore = orddict:merge(Fun, State#state.map_commands_in_transit, CmdOrddictNewQueues),
%%  TODO: add sched_event about de-registeration
%%  SchedEvent = #sched_event{what = reg_node, id = State#state.id_counter, name = NodeName},
%%  NextId = State#state.id_counter + 1,
%%  msg_interception_helpers:submit_sched_event(SchedEvent),
  {reply, ok, State#state{registered_node_pids = NewRegisteredPidNodes
%%    map_commands_in_transit = NewCommandStore,
%%    id_counter = NextId
 }};
handle_call({msg_cmd, {FromPid, ToAtom, Module, Fun, Args}}, _From, State = #state{}) when is_atom(ToAtom) ->
  logger:notice("[~p] got msg_cmd for ~p. Trying to find pid for ~p in table ~p", [?MODULE, ToAtom, atom_to_list(ToAtom), ets:tab2list(pid_name_table)]),
  PidList = ets:match(pid_name_table, {'$1', atom_to_list(ToAtom)}),
  if length(PidList) > 1 -> logger:warning("[~p] found more than one valid PID: ~p trying the newest.", [?MODULE, PidList]);
     true -> ok end,
  [ToPid] = lists:last(PidList),
  logger:notice("[~p] using pid ~p for ~p.", [?MODULE, ToPid, ToAtom]),
  handle_call({msg_cmd, {FromPid, ToPid, Module, Fun, Args}}, _From, State);
handle_call({msg_cmd, {FromPid, ToPid, Module, Fun, Args}}, _From, State = #state{})
  when not is_tuple(ToPid)->
  case is_pid(ToPid) of
    true -> ok;
    false -> logger:error("[~p] Expected PID but got ~p in msg_cmd", [?MODULE, ToPid]) end,
  Bool_crashed = check_if_crashed(State, ToPid) or check_if_crashed(State, FromPid),
%%  Bool_whitelisted = check_if_whitelisted(Module, Fun, Args),
  if
    Bool_crashed ->
      SchedEvent = #sched_event{what = cmd_rcv_crsh, id = State#state.id_counter,
        from = FromPid, to = ToPid, mod = Module, func = Fun, args = Args},
      msg_interception_helpers:submit_sched_event(SchedEvent),
      NextID = State#state.id_counter + 1,
      {reply, ok, State#state{id_counter = NextID}};  % if crashed, do also not let whitelisted trough
%%    Bool_whitelisted -> do_exec_cmd(Module, Fun, Args),
%%      {noreply, State};
    true ->
      QueueToUpdate = orddict:fetch({FromPid, ToPid}, State#state.map_commands_in_transit),
      UpdatedQueue = queue:in({State#state.id_counter, Module, Fun, Args}, QueueToUpdate),
      UpdatedCommandsInTransit = orddict:store({FromPid, ToPid}, UpdatedQueue, State#state.map_commands_in_transit),
%%      UpdatedListCommandsInTransit = State#state.list_commands_in_transit ++
%%        [{State#state.id_counter, From, To, Module, Fun, Args}],
      UpdatedListCommandsInTransit =
        [ {State#state.id_counter, FromPid, ToPid, Module, Fun, Args} | State#state.list_commands_in_transit ],
      SchedEvent = #sched_event{what = cmd_rcv, id = State#state.id_counter,
        from = FromPid, to = ToPid, mod = Module, func = Fun, args = Args},
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
  ListQueuesToEmpty = [{Other, NodeName} || Other <- get_all_node_pids_from_state(State), Other /= NodeName],
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
  ListQueuesToDelete = [{Other, NodeName} || Other <- get_all_node_pids_from_state(State), Other /= NodeName],
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
-spec handle_cast(_, #state{}) -> {'noreply', #state{}}.
handle_cast(Msg, State) ->
  io:format("[cb] received unhandled cast: ~p~n", [Msg]),
  {noreply, State}.


-spec(handle_info(Info :: timeout() | term(), State :: #state{}) ->
  {noreply, NewState :: #state{}} |
  {noreply, NewState :: #state{}, timeout() | hibernate} |
  {stop, Reason :: term(), NewState :: #state{}}).
handle_info(_Info, State = #state{}) ->
  {noreply, State}.

-spec terminate(_, #state{}) -> 'ok'.
terminate(Reason, _State = #state{}) ->
  io:format("[?MODULE] Terminating. Reason: ~p~n", [Reason]),
  ok.

-spec code_change(_, #state{}, _) -> {'ok', #state{}}.
code_change(_OldVsn, State = #state{}, _Extra) ->
  {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

%%node_to_pid(State, Node) ->
%%  {ok, Pid} = orddict:find(Node, State#state.registered_nodes_pid),
%%  Pid.

% -spec pid_to_node(#state{}, pid()) -> nonempty_string().
% pid_to_node(State, Pid) ->
%   case orddict:find(Pid, State#state.registered_pid_nodes) of
%     {ok, Node} -> Node;
%     _ -> NameInTable = ets:lookup(pid_name_table, Pid),
%       erlang:display(["NameInTable", NameInTable]),
%       erlang:error([pid_not_registered, Pid])
%   end.

-spec check_if_crashed(#state{}, pid()) -> boolean().
check_if_crashed(State, To) ->
  sets:is_element(To, State#state.transient_crashed_nodes) or sets:is_element(To, State#state.permanent_crashed_nodes).

-spec get_all_node_pids_from_state(#state{}) -> [pid()].
get_all_node_pids_from_state(State) ->
  sets:to_list(State#state.registered_node_pids).

-spec find_cmd_and_get_updated_commands_in_transit(#state{}, atom(), pid(), pid()) -> {atom(), atom(), [any()], [command()], [command()]}.
find_cmd_and_get_updated_commands_in_transit(State, Id, From, To) ->
  QueueToSearch = orddict:fetch({From, To}, State#state.map_commands_in_transit),
  {Mod, Func, Args, Skipped, UpdatedQueue} = find_cmd_id_in_queue(QueueToSearch, Id),
  NewCommandStore = orddict:store({From, To}, UpdatedQueue, State#state.map_commands_in_transit),
  {Mod, Func, Args, Skipped, NewCommandStore}.

-spec do_exec_cmd(atom() | tuple(), atom(), [any()]) -> any().
do_exec_cmd(Mod, Func, Args) ->
  erlang:apply(Mod, Func, Args).

-spec find_cmd_id_in_queue(queue:queue(_), atom()) -> {_, _, _, [command()], queue:queue(_)}.
find_cmd_id_in_queue(QueueToSearch, Id) ->
  find_cmd_id_in_queue([], QueueToSearch, Id).

-spec find_cmd_id_in_queue([command()], queue:queue(_), atom()) -> {atom(), atom(), [any()], [command()], queue:queue(_)}.
find_cmd_id_in_queue(SkippedList, TailQueueToSearch, Id) ->
  % io:format("[~p] trying to find cmd_id ~p in queue ~p", [?MODULE, Id, TailQueueToSearch]),
  Result = queue:out(TailQueueToSearch),
  {{value, {CurrentId, Mod, Func, Args}}, NewTailQueueToSearch} = Result,
  case CurrentId == Id  of
    true -> ReversedSkipped = lists:reverse(SkippedList),
      {Mod, Func, Args, ReversedSkipped, queue:join(queue:from_list(ReversedSkipped), NewTailQueueToSearch)};
    false -> find_cmd_id_in_queue([{CurrentId, Mod, Func, Args} | SkippedList], NewTailQueueToSearch, Id)
  end.

-spec find_timeout_and_get_updated_ones(#state{}, timerref()) -> {'found', {mil_timeout(), [mil_timeout()]}} | {'notfound', 'undefined'}.
find_timeout_and_get_updated_ones(#state{enabled_timeouts = EnabledTimeouts}, TimerRef) ->
  FilterFunction = fun({TimerRef1,_ , _, _, _, _, _}) -> TimerRef == TimerRef1  end,
  {RetrievedTimeoutList, NewEnabledTimeouts} = lists:partition(FilterFunction, EnabledTimeouts),
  case RetrievedTimeoutList of
    [RetrievedTimeout] -> {found, {RetrievedTimeout, NewEnabledTimeouts}};
    [] -> {notfound, undefined};
    _ -> erlang:throw("multipled timeouts with the same timerref")
  end.