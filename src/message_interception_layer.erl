%%%-------------------------------------------------------------------
%%% @author fms
%%% @copyright (C) 2021, <COMPANY>
%%% @doc
%%% @end
%%%-------------------------------------------------------------------
-module(message_interception_layer).

-include_lib("sched_event.hrl").

-behaviour(gen_server).

-export([start_msg_int_layer/1, register_with_name/4, register_client/2,
  duplicate_msg_command/4, alter_msg_command/5, transient_crash/2, rejoin/2,
  permanent_crash/2, msg_command/6, exec_msg_command/7, enable_timeout/5, disable_timeout/3,
  drop_msg_command/4, enable_timeout/4, fire_timeout/3, poll_timeouts/1]).
-export([start/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2,
  code_change/3]).

-define(SERVER, ?MODULE).
-define(INTERVAL, 50).

-record(state, {
  registered_nodes_pid = orddict:new() :: orddict:orddict(Name::atom(), pid()),
  registered_pid_nodes = orddict:new() :: orddict:orddict(pid(), Name::atom()),
  client_nodes = orddict:new() :: orddict:orddict(Name::atom(), pid()),
  transient_crashed_nodes = sets:new() :: sets:set(atom()),
  permanent_crashed_nodes = sets:new() :: sets:set(atom()),
  commands_in_transit = orddict:new() :: orddict:orddict(FromTo::any(),
                              queue:queue({ID::any(), Module::atom(), Function::atom(), Args::list(any())})),
  new_commands_in_transit = [] :: [{ID::any(), From::pid(), To::pid(), Module::atom(), Function::atom(), ListArgs::list(any())}],
  enabled_timeouts = orddict:new() :: orddict:orddict(Proc::any(),
                                                      orddict:orddict({TimerRef::reference(), {Time::any(), Module::pid(), Function::atom(), ListArgs::list(any())}})),
%%  scheduler_id is only used to send the new_events, we could also request these with the scheduler
  scheduler_id :: pid(),
  id_counter = 0 :: any()
}).

%%%===================================================================
%%% Functions for External Use
%%%===================================================================

start_msg_int_layer(MIL) ->
  gen_server:cast(MIL, {start}).

%% registration of processes

register_with_name(MIL, Name, Identifier, Kind) -> % Identifier can be PID or ...
  gen_server:cast(MIL, {register, {Name, Identifier, Kind}}).

register_client(MIL, Name) ->
  gen_server:cast(MIL, {register_client, {Name}}).

%% msg_commands

msg_command(MIL, From, {To, _Node}, Module, Fun, Args) ->
%%  TODO: this is a hack currently and does only work with one single nonode@... which is Node
  msg_command(MIL, From, To, Module, Fun, Args);
%%
msg_command(MIL, From, To, Module, Fun, Args) ->
  gen_server:cast(MIL, {msg_cmd, {From, To, Module, Fun, Args}}).

exec_msg_command(MIL, ID, From, To, Module, Fun, Args) ->
  gen_server:cast(MIL, {exec_msg_cmd, {ID, From, To, Module, Fun, Args}}).

duplicate_msg_command(MIL, ID, From, To) ->
  gen_server:cast(MIL, {duplicate, {ID, From, To}}).

%% TODO: change parameters
alter_msg_command(MIL, Id, From, To, NewArgs) ->
  gen_server:cast(MIL, {send_altered, {Id, From, To, NewArgs}}).

%% TODO: change parameters
drop_msg_command(MIL, Id, From, To) ->
  gen_server:cast(MIL, {drop, {Id, From, To}}).

%% timeouts

enable_timeout(MIL, Time, Dest, Msg) ->
  enable_timeout(MIL, Time, Dest, Msg, undefined).

enable_timeout(MIL, Time, Dest, Msg, _Options) ->
%%  we assume that processes do only send timeouts to themselves and ignore Options
%%  the Args will be updated with the TimerRef
%%  erlang:display(["Time", Time, "Dest", Dest, "Msg", Msg]),
  TimerRef = gen_server:call(MIL, {enable_to, {Time, Dest, Dest, erlang, send, [{mil_timeout, Msg}]}}),
  TimerRef.

disable_timeout(MIL, Proc, TimerRef) ->
  Result = gen_server:call(MIL, {disable_to, {Proc, TimerRef}}),
  Result.

fire_timeout(MIL, Proc, TimerRef) ->
  Result = gen_server:call(MIL, {fire_to, {Proc, TimerRef}}),
  Result.

poll_timeouts(MIL) ->
  EnabledTimeouts = gen_server:call(MIL, {poll_to}),
  EnabledTimeouts.

%% client requests, removed for the time being
%%client_req(MIL, ClientName, Coordinator, ClientCmd) ->
%%  gen_server:cast(MIL, {client_req, {ClientName, Coordinator, ClientCmd}}).
%%forward_client_req(MIL, ClientName, Coordinator, ClientCmd) ->
%%  gen_server:cast(MIL, {fwd_client_req, {ClientName, Coordinator, ClientCmd}}).

%% crashing and rejoining

transient_crash(MIL, Name) ->
  gen_server:cast(MIL, {crash_trans, {Name}}).

rejoin(MIL, Name) ->
  gen_server:cast(MIL, {rejoin, {Name}}).

permanent_crash(MIL, Name) ->
  gen_server:cast(MIL, {crash_perm, {Name}}).


%%%===================================================================
%%% Spawning and gen_server implementation
%%%===================================================================

start(Scheduler) ->
  gen_server:start_link(?MODULE, [Scheduler], []).

init([Scheduler]) ->
  {ok, #state{scheduler_id = Scheduler}}.

handle_call({enable_to, {Time, ProcPid, ProcPid, Module, Fun, [{mil_timeout, MsgContent}]}}, _From,
    State = #state{})
  when not is_tuple(ProcPid)->
  TimerRef = make_ref(),
  Args = [ProcPid, {mil_timeout, TimerRef, MsgContent}],
  Proc = pid_to_node(State, ProcPid),
  Bool_crashed = check_if_crashed(State, Proc) or check_if_crashed(State, Proc),
  case Bool_crashed of
    true ->
%%      still log this event for matching later on
      logger:info("enable_to_crsh", #{what => enable_to_crsh, id => State#state.id_counter,
        from => Proc, to => Proc, mod => Module, func => Fun, args => Args}),
      NextID = State#state.id_counter + 1,
      {reply, TimerRef, State#state{id_counter = NextID}};  % if crashed, do also not let whitelisted trough
    _ ->
      OrddictToUpdate = orddict:fetch(Proc, State#state.enabled_timeouts),
      UpdatedOrddict = orddict:append(TimerRef, {Time, Module, Fun, Args}, OrddictToUpdate),
      UpdatedEnabledTimeouts = orddict:store(Proc, UpdatedOrddict, State#state.enabled_timeouts),
      logger:info("enable_to", #{what => enable_to, id => TimerRef,
        from => Proc, to => Proc, mod => Module, func => Fun, args => Args}),
%%      erlang:display(["enable_to", "MsgRef", MsgRef, "From", Proc, "To", Proc, "Mod", Module, "Func", Fun, "Args", Args]),
      {reply, TimerRef, State#state{enabled_timeouts = UpdatedEnabledTimeouts}}
  end;
handle_call({disable_to, {ProcPid, TimerRef}}, _From, State = #state{}) ->
  Proc = pid_to_node(State, ProcPid),
  {_TimeoutValue, NewEnabledTimeouts} = find_enabled_timeouts_and_get_updated_ones_in_transit(State, Proc, TimerRef),
%%  erlang:display(["disable_to", "Id", MsgRef, "From", Proc, "To", Proc]),
  logger:info("disable_to", #{what => disable_to, id => TimerRef,
    from => Proc, to => Proc}),
  {reply, true, State#state{enabled_timeouts = NewEnabledTimeouts}};
handle_call({fire_to, {Proc, TimerRef}}, _From, State = #state{}) ->
%%  Proc = pid_to_node(State, ProcPid),
  {TimeoutValue, NewEnabledTimeouts} = find_enabled_timeouts_and_get_updated_ones_in_transit(State, Proc, TimerRef),
%%  erlang:display(["fire_to", "Id", TimerRef, "From", Proc, "To", Proc]),
  [{_Time, Mod, Func, Args}] = TimeoutValue,
  erlang:apply(Mod, Func, Args),
  logger:info("fire_to", #{what => fire_to, id => TimerRef,
    from => Proc, to => Proc}),
  {reply, true, State#state{enabled_timeouts = NewEnabledTimeouts}};
handle_call({poll_to}, _From, State = #state{}) ->
%%  erlang:display(["poll_to"]),
  {reply, State#state.enabled_timeouts, State};
handle_call(_Request, _From, State) ->
  erlang:throw("unhandled call"),
  {reply, ok, State}.

handle_cast({start}, State) ->
  erlang:send_after(?INTERVAL, self(), trigger_get_events),
  {noreply, State};
%%
handle_cast({register, {NodeName, NodePid, NodeClass}}, State = #state{}) ->
%%  erlang:display(atom_to_list(NodeName) ++ " registered with " ++ pid_to_list(NodePid)),
  NewRegisteredNodesPid = orddict:store(NodeName, NodePid, State#state.registered_nodes_pid),
  NewRegisteredPidNodes = orddict:store(NodePid, NodeName, State#state.registered_pid_nodes),
  AllOtherNames = get_all_node_names(State),
  CmdListNewQueues = [{{Other, NodeName}, queue:new()} || Other <- AllOtherNames] ++
                  [{{NodeName, Other}, queue:new()} || Other <- AllOtherNames],
  CmdOrddictNewQueues = orddict:from_list(CmdListNewQueues),
  Fun = fun({_, _}, _, _) -> undefined end,
  NewCommandStore = orddict:merge(Fun, State#state.commands_in_transit, CmdOrddictNewQueues),
  NewTimeoutList = orddict:store(NodeName, orddict:new(), State#state.enabled_timeouts),
  logger:info("registration", #{what => reg_node, name => NodeName, class => NodeClass}),
  {noreply, State#state{registered_nodes_pid = NewRegisteredNodesPid, registered_pid_nodes = NewRegisteredPidNodes,
                        commands_in_transit = NewCommandStore,
                        enabled_timeouts = NewTimeoutList}};
%%
handle_cast({register_client, {ClientName}}, State = #state{}) ->
  {ok, Pid} = client_node:start(ClientName, self()),
  NewClientDict = orddict:store(ClientName, Pid, State#state.client_nodes),
  logger:info("regst_client", #{what => reg_clnt, name => ClientName}),
  {noreply, State#state{client_nodes = NewClientDict}};
%%
handle_cast({msg_cmd, {FromPid, ToPid, Module, Fun, Args}}, State = #state{})
  when not is_tuple(ToPid)->
%%  erlang:display(["FromPid", FromPid, "ToPid", ToPid]),
  From = pid_to_node(State, FromPid),
  To = case is_pid(ToPid) of
         true -> pid_to_node(State, ToPid);
         _ -> ToPid
       end,
  Bool_crashed = check_if_crashed(State, To) or check_if_crashed(State, From),
  Bool_whitelisted = check_if_whitelisted(Module, Fun, Args),
  if
    Bool_crashed ->
%%      still log this event for matching later on
      logger:info("cmd_rcv_crsh", #{what => cmd_rcv_crsh, id => State#state.id_counter,
                                    from => From, to => To, mod => Module, func => Fun, args => Args}),
      NextID = State#state.id_counter + 1,
      {noreply, State#state{id_counter = NextID}};  % if crashed, do also not let whitelisted trough
    Bool_whitelisted -> do_exec_cmd(Module, Fun, Args),
      {noreply, State};
    true ->
      QueueToUpdate = orddict:fetch({From, To}, State#state.commands_in_transit),
      UpdatedQueue = queue:in({State#state.id_counter, Module, Fun, Args}, QueueToUpdate),
      UpdatedCommandsInTransit = orddict:store({From, To}, UpdatedQueue, State#state.commands_in_transit),
      UpdatedNewCommandsInTransit = State#state.new_commands_in_transit ++
                                    [{State#state.id_counter, From, To, Module, Fun, Args}],
      logger:info("cmd_rcv", #{what => cmd_rcv, id => State#state.id_counter,
                                from => From, to => To, mod => Module, func => Fun, args => Args}),
      NextID = State#state.id_counter + 1,
      {noreply, State#state{commands_in_transit = UpdatedCommandsInTransit,
        new_commands_in_transit = UpdatedNewCommandsInTransit,
        id_counter = NextID}}
  end;
%%
handle_cast({exec_msg_cmd, {Id, From, To, _Module, _Fun, Args}}, State = #state{}) ->
  {Mod, Func, Args, Skipped, NewCommandStore} = find_cmd_and_get_updated_commands_in_transit(State, Id, From, To),
  do_exec_cmd(Mod, Func, Args),
%%  erlang:display(["exec_msg_cmd", "Id", Id, "From", From, "To", To, "Mod", Mod, "Func", Func, "Args", Args]),
  logger:info("exec_msg_cmd", #{what => exec_msg_cmd, id => Id,
                                from => From, to => To, skipped => Skipped,
                                mod => Mod, func => Func, args => Args}),
  {noreply, State#state{commands_in_transit = NewCommandStore}};
%%
%% TODO: change to "wait for new events" or similiar
handle_cast({noop, {}}, State = #state{}) ->
%%  erlang:display("reach noop"),
  {noreply, State};
%%
handle_cast({duplicate, {Id, From, To}}, State = #state{}) ->
  {Mod, Func, Args, Skipped, _NewCommandStore} =
      find_cmd_and_get_updated_commands_in_transit(State, Id, From, To),
  do_exec_cmd(Mod, Func, Args),
  logger:info("duplicat", #{what => duplicat, id => Id, from => From, to => To,
                            mod => Mod, func => Func, args => Args, skipped => Skipped}),
%%  we do not update state since we duplicate
  {noreply, State};
%%
handle_cast({send_altered, {Id, From, To, NewArgs}}, State = #state{}) ->
  {Mod, Func, _Args, Skipped, NewCommandStore} =
    find_cmd_and_get_updated_commands_in_transit(State, Id, From, To),
  do_exec_cmd(Mod, Func, NewArgs),
%%  TODO: update the commands
  logger:info("snd_altr", #{what => snd_altr, id => Id, from => From, to => To,
                            mod => Mod, func => Func, args => NewArgs, skipped => Skipped}),
  {noreply, State#state{commands_in_transit = NewCommandStore}};
%%
handle_cast({drop, {Id, From, To}}, State = #state{}) ->
  {Mod, Func, Args, Skipped, NewCommandStore} =
    find_cmd_and_get_updated_commands_in_transit(State, Id, From, To),
  logger:info("drop_msg", #{what => drop_msg, id => Id, from => From, to => To, mod => Mod, func => Func, args => Args, skipped => Skipped}),
  {noreply, State#state{commands_in_transit = NewCommandStore}};
%%
%% removed client requests for the time being
%%handle_cast({client_req, {ClientName, Coordinator, ClientCmd}}, State = #state{}) ->
%%  gen_server:cast(client_pid(State, ClientName), {client_req, ClientName, Coordinator, ClientCmd}),
%%  logger:info("clnt_req", #{what => clnt_req, from => ClientName, to => Coordinator, mesg => ClientCmd}),
%%  {noreply, State};
%%
%%handle_cast({fwd_client_req, {ClientName, Coordinator, ClientCmd}}, State = #state{}) ->
%%  send_client_req(State, ClientName, Coordinator, ClientCmd),
%%%%  logged when issued
%%  {noreply, State};
%%
handle_cast({crash_trans, {NodeName}}, State = #state{}) ->
  UpdatedCrashTrans = sets:add_element(NodeName, State#state.transient_crashed_nodes),
  ListQueuesToEmpty = [{Other, NodeName} || Other <- get_all_node_names(State), Other /= NodeName],
  NewCommandsStore = lists:foldl(fun({From, To}, SoFar) -> orddict:store({From, To}, queue:new(), SoFar) end,
              State#state.commands_in_transit,
              ListQueuesToEmpty),
%%  in order to let a schedule replay, we do not need to log all the dropped messages due to crashes
  logger:info("trans_crs", #{what => trns_crs, name => NodeName}),
  {noreply, State#state{transient_crashed_nodes = UpdatedCrashTrans, commands_in_transit = NewCommandsStore}};
%%
handle_cast({rejoin, {NodeName}}, State = #state{}) ->
%%  for transient crashes only
  UpdatedCrashTrans = sets:del_element(NodeName, State#state.transient_crashed_nodes),
  logger:info("rejoin", #{what => rejoin, name => NodeName}),
  {noreply, State#state{transient_crashed_nodes = UpdatedCrashTrans}};
handle_cast({crash_perm, {NodeName}}, State = #state{}) ->
%%  for now, we keep the outgoing channels since these are messages that were sent before (still scheduable)
  UpdatedCrashPerm = sets:add_element(NodeName, State#state.permanent_crashed_nodes),
  ListQueuesToDelete = [{Other, NodeName} || Other <- get_all_node_names(State), Other /= NodeName],
  NewCommandStore = lists:foldl(fun({From, To}, SoFar) -> orddict:erase({From, To}, SoFar) end,
    State#state.commands_in_transit,
    ListQueuesToDelete),
%%  in order to let a schedule replay, we do not need to log all the dropped messages due to crashes
  logger:info("perm_crsh", #{what => perm_crs, name => NodeName}),
  {noreply, State#state{permanent_crashed_nodes = UpdatedCrashPerm, commands_in_transit = NewCommandStore}}.


handle_info(trigger_get_events, State = #state{}) ->
  gen_server:cast(State#state.scheduler_id, {new_events, State#state.new_commands_in_transit}),
  restart_timer(),
  {noreply, State#state{new_commands_in_transit = []}}.

terminate(_Reason, _State = #state{}) ->
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
    _ -> erlang:error(pid_not_registered)
  end.

%%client_pid(State, Node) ->
%%  {ok, Pid} = orddict:find(Node, State#state.client_nodes),
%%  Pid.
%%
%%send_client_req(State, From, To, Msg) ->
%%  gen_server:cast(To, {message, client_pid(State, From), node_pid(State, To), Msg}).

restart_timer() ->
  erlang:send_after(?INTERVAL, self(), trigger_get_events).

check_if_whitelisted(_Module, _Fun, _Args) ->
%%  TODO: implement whitelist check, currently none whitelisted
  false.

check_if_crashed(State, To) ->
  sets:is_element(To, State#state.transient_crashed_nodes) or sets:is_element(To, State#state.permanent_crashed_nodes).

get_all_node_names(State) ->
  orddict:fetch_keys(State#state.registered_nodes_pid).

%%find_id_in_queue(QueueToSearch, Id) ->
%%  find_id_in_queue([], QueueToSearch, Id).
%%
find_id_in_queue(SkippedList, TailQueueToSearch, Id) ->
  {{value, {CurrentId, CurrentPayload}}, NewTailQueueToSearch} = queue:out(TailQueueToSearch),
  case CurrentId == Id  of
    true -> ReversedSkipped = lists:reverse(SkippedList),
            {CurrentPayload, ReversedSkipped, queue:join(queue:from_list(ReversedSkipped), NewTailQueueToSearch)};
%%    skipped does only contain the IDs
    false -> find_id_in_queue([CurrentId | SkippedList], NewTailQueueToSearch, Id)
%%  TODO: assumes that ID is in there
  end.

find_cmd_and_get_updated_commands_in_transit(State, Id, From, To) ->
  QueueToSearch = orddict:fetch({From, To}, State#state.commands_in_transit),
  {Mod, Func, Args, Skipped, UpdatedQueue} = find_cmd_id_in_queue(QueueToSearch, Id),
  NewCommandStore = orddict:store({From, To}, UpdatedQueue, State#state.commands_in_transit),
  {Mod, Func, Args, Skipped, NewCommandStore}.

do_exec_cmd(Mod, Func, Args) ->
  erlang:apply(Mod, Func, Args).

%% TODO: unify later

find_cmd_id_in_queue(QueueToSearch, Id) ->
  find_cmd_id_in_queue([], QueueToSearch, Id).

find_cmd_id_in_queue(SkippedList, TailQueueToSearch, Id) ->
  {{value, {CurrentId, Mod, Func, Args}}, NewTailQueueToSearch} = queue:out(TailQueueToSearch),
  case CurrentId == Id  of
    true -> ReversedSkipped = lists:reverse(SkippedList),
      {Mod, Func, Args, ReversedSkipped, queue:join(queue:from_list(ReversedSkipped), NewTailQueueToSearch)};
%%    skipped does only contain the IDs TODO, change this
    false -> find_id_in_queue([CurrentId | SkippedList], NewTailQueueToSearch, Id)
%%  TODO: assumes that ID is in there
  end.

find_enabled_timeouts_and_get_updated_ones_in_transit(State, Proc, TimerRef) ->
  OrddictToSearch = orddict:fetch(Proc, State#state.enabled_timeouts),
  Result = orddict:take(TimerRef, OrddictToSearch),
  {Value, UpdatedOrddict} =
    case Result of
      {SomeValue, OrddictWO} -> {SomeValue, OrddictWO};
      error -> erlang:display("attempt to disable timeout which was not enabled"),
                        {undefined, OrddictToSearch}
    end,
  NewEnabledTimeouts = orddict:store(Proc, UpdatedOrddict, State#state.enabled_timeouts),
  {Value, NewEnabledTimeouts}.