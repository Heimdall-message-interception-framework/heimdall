%%%-------------------------------------------------------------------
%%% @author fms
%%% @copyright (C) 2021, <COMPANY>
%%% @doc
%%% @end
%%%-------------------------------------------------------------------
-module(message_interception_layer).

-include_lib("sched_event.hrl").

-behaviour(gen_server).

-export([start_msg_int_layer/1, register_with_name/4, register_client/2, cast_msg/4, no_op/1,
  duplicate_msg/4, send_altered_msg/5, drop_msg/4, client_req/4, forward_client_req/4, transient_crash/2, rejoin/2,
  permanent_crash/2, send_msg/4, msg_to_be_sent/4, msg_command/6, exec_msg_command/7, enable_timeout/3, disable_timeout/3]).
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
  messages_in_transit = orddict:new() :: orddict:orddict(FromTo::any(),
                                        queue:queue({ID::any(), Payload::any()})),
  new_messages_in_transit = [] :: [{ID::any(), From::pid(), To::pid(), Msg::any()}],
  commands_in_transit = orddict:new() :: orddict:orddict(FromTo::any(),
                              queue:queue({ID::any(), Module::atom(), Function::atom(), Args::list(any())})),
  new_commands_in_transit = [] :: [{ID::any(), From::pid(), To::pid(), Module::atom(), Function::atom(), ListArgs::list(any())}],
  enabled_timeouts = orddict:new() :: orddict:orddict(Proc::any(), queue:queue(any())),
%%  scheduler_id is only used to send the new_events, we could also request these with the scheduler
  scheduler_id :: pid(),
  id_counter = 0 :: any(),
  bc_nodes = sets:new() :: sets:set(atom())
}).

%%%===================================================================
%%% Functions for External Use
%%%===================================================================

start_msg_int_layer(MIL) ->
  gen_server:cast(MIL, {start}).

register_with_name(MIL, Name, Identifier, Kind) -> % Identifier can be PID or ...
  gen_server:cast(MIL, {register, {Name, Identifier, Kind}}).

%% TODO
%%register_spawned_process(MIL, Parent, Pid, ModName) -> % Pid of spawned process
%%  assumption: parent is pid and already registered
%%  currently, we compute the name of the process from its PID and the parent
%%  ParentName = pid_node(Parent),
%%  Name = ParentName ++ "->" ++ pid_to_list(Pid),
%%  gen_server:cast(MIL, {register_spawned, {Parent, Pid, ModName}}).

register_client(MIL, Name) ->
  gen_server:cast(MIL, {register_client, {Name}}).

cast_msg(MIL, From, To, Message) ->
  gen_server:cast(MIL, {cast_msg, From, To, Message}).

msg_command(MIL, From, {To, _Node}, Module, Fun, Args) ->
%%  TODO: this is a hack currently and does only work with one single nonode@... which is Node
  msg_command(MIL, From, To, Module, Fun, Args);
%%
msg_command(MIL, From, To, Module, Fun, Args) ->
  gen_server:cast(MIL, {msg_cmd, {From, To, Module, Fun, Args}}).

exec_msg_command(MIL, ID, From, To, Module, Fun, Args) ->
  gen_server:cast(MIL, {exec_msg_cmd, {ID, From, To, Module, Fun, Args}}).

enable_timeout(MIL, Proc, MsgRef) ->
  enable_timeout(MIL, Proc, MsgRef, undefined).

enable_timeout(MIL, Proc, MsgRef, MsgContent) ->
  gen_server:cast(MIL, {enable_to, {Proc, Proc, erlang, send, [{mil_timeout, MsgRef, MsgContent}]}}).

disable_timeout(MIL, Proc, MsgRef) ->
  gen_server:cast(MIL, {disable_to, {Proc, MsgRef}}).

msg_to_be_sent(MIL, From, {To, _Node}, Payload) ->
%%  TODO: this is a hack currently and does only work with one single nonode@... which is Node
  msg_to_be_sent(MIL, From, To, Payload);
%%
msg_to_be_sent(MIL, From, To, Message) ->
  gen_server:cast(MIL, {bang, {From, To, Message}}).

no_op(MIL) ->
  gen_server:cast(MIL, {noop, {}}).

send_msg(MIL, Id, From, To) -> % TODO: difference to cast_msg?
  gen_server:cast(MIL, {send, {Id, From, To}}).

duplicate_msg(MIL, Id, From, To) ->
  gen_server:cast(MIL, {duplicate, {Id, From, To}}).

send_altered_msg(MIL, Id, From, To, NewPayload) ->
  gen_server:cast(MIL, {send_altered, {Id, From, To, NewPayload}}).

drop_msg(MIL, Id, From, To) ->
  gen_server:cast(MIL, {drop, {Id, From, To}}).

client_req(MIL, ClientName, Coordinator, ClientCmd) ->
  gen_server:cast(MIL, {client_req, {ClientName, Coordinator, ClientCmd}}).

forward_client_req(MIL, ClientName, Coordinator, ClientCmd) ->
  gen_server:cast(MIL, {fwd_client_req, {ClientName, Coordinator, ClientCmd}}).

transient_crash(MIL, Name) ->
  gen_server:cast(MIL, {crash_trans, {Name}}).

rejoin(MIL, Name) ->
  gen_server:cast(MIL, {rejoin, {Name}}).

permanent_crash(MIL, Name) ->
  gen_server:cast(MIL, {crash_perm, {Name}}).

%% TBC: do we also need this regularly?
%%handle_info(trigger_get_events, State = #state{}) ->

%%%===================================================================
%%% Spawning and gen_server implementation
%%%===================================================================

start(Scheduler) ->
  gen_server:start_link(?MODULE, [Scheduler], []).

init([Scheduler]) ->
  {ok, #state{scheduler_id = Scheduler}}.

handle_call({all_bc_pids}, _From, State = #state{}) ->
  AllPids = lists:map(fun(Name) -> node_pid(State, Name) end, sets:to_list(State#state.bc_nodes)),
  {reply, AllPids, State};
handle_call({reg_bc_node, {NodeName}}, _From, State = #state{}) ->
  NewBcNodes = sets:add_element(NodeName, State#state.bc_nodes),
  {reply, ok, State#state{bc_nodes = NewBcNodes}};
handle_call(_Request, _From, State) ->
  {reply, ok, State}.

handle_cast({start}, State) ->
  erlang:send_after(?INTERVAL, self(), trigger_get_events),
  {noreply, State};
%%
handle_cast({register, {NodeName, NodePid, NodeClass}}, State = #state{}) ->
  erlang:display(atom_to_list(NodeName) ++ " registered with " ++ pid_to_list(NodePid)),
  NewRegisteredNodesPid = orddict:store(NodeName, NodePid, State#state.registered_nodes_pid),
  NewRegisteredPidNodes = orddict:store(NodePid, NodeName, State#state.registered_pid_nodes),
  AllOtherNames = get_all_node_names(State),
  MsgListNewQueues = [{{Other, NodeName}, queue:new()} || Other <- AllOtherNames] ++
                  [{{NodeName, Other}, queue:new()} || Other <- AllOtherNames],
  MsgOrddictNewQueues = orddict:from_list(MsgListNewQueues),
  CmdListNewQueues = [{{Other, NodeName}, queue:new()} || Other <- AllOtherNames] ++
                  [{{NodeName, Other}, queue:new()} || Other <- AllOtherNames],
  CmdOrddictNewQueues = orddict:from_list(CmdListNewQueues),
  Fun = fun({_, _}, _, _) -> undefined end,
  NewMessageStore = orddict:merge(Fun, State#state.messages_in_transit, MsgOrddictNewQueues),
  NewCommandStore = orddict:merge(Fun, State#state.commands_in_transit, CmdOrddictNewQueues),
  NewTimeoutList = orddict:store(NodeName, queue:new(), State#state.enabled_timeouts),
  logger:info("registration", #{what => reg_node, name => NodeName, class => NodeClass}),
  {noreply, State#state{registered_nodes_pid = NewRegisteredNodesPid, registered_pid_nodes = NewRegisteredPidNodes,
                        messages_in_transit = NewMessageStore, commands_in_transit = NewCommandStore,
                        enabled_timeouts = NewTimeoutList}};
%%
handle_cast({register_client, {ClientName}}, State = #state{}) ->
  {ok, Pid} = client_node:start(ClientName, self()),
  NewClientDict = orddict:store(ClientName, Pid, State#state.client_nodes),
  logger:info("regst_client", #{what => reg_clnt, name => ClientName}),
  {noreply, State#state{client_nodes = NewClientDict}};
%%
handle_cast({cast_msg, From, To, Message}, State = #state{}) ->
  erlang:display("cast_msg"),
%%handle_cast({cast_msg, From, To, {Message}}, State = #state{}) ->
%%  this can be used to replay also the function calls to participants interacting (e.g. to initiate sending messages)
  FromPid = node_pid(State, From),
  ToPid = node_pid(State, To),
  logger:info("cast_msg", #{what => cast_msg, from => From, to => To, mesg => Message}),
  gen_server:cast(FromPid, {casted, ToPid, Message}),
  {noreply, State};
%%
handle_cast({msg_cmd, {FromPid, ToPid, Module, Fun, Args}}, State = #state{})
  when not is_tuple(ToPid)->
%%  erlang:display(["FromPid", FromPid, "ToPid", ToPid]),
  From = pid_node(State, FromPid),
  To = case is_pid(ToPid) of
         true -> pid_node(State, ToPid);
         _ -> ToPid
       end,
%%  erlang:display(["From", From, "To", To]),
  Bool_crashed = check_if_crashed(State, To) or check_if_crashed(State, From),
%%  Bool_whitelisted = check_if_whitelisted(From, To, Payload),
  if
    Bool_crashed ->
%%      still log this event for matching later on
      logger:info("cmd_rcv_crsh", #{what => cmd_rcv_crsh, id => State#state.id_counter,
                                    from => From, to => To, mod => Module, func => Fun, args => Args}),
      NextID = State#state.id_counter + 1,
      {noreply, State#state{id_counter = NextID}};  % if crashed, do also not let whitelisted trough
%%    Bool_whitelisted -> do_cast_cmd(State, FromPid, ToPid, Payload),
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
      erlang:display(["msg_cmd", "Id", State#state.id_counter, "From", From, "To", To, "Mod", Module, "Func", Fun, "Args", Args]),
      {noreply, State#state{commands_in_transit = UpdatedCommandsInTransit,
        new_commands_in_transit = UpdatedNewCommandsInTransit,
        id_counter = NextID}}
  end;
%%
handle_cast({exec_msg_cmd, {Id, From, To, _Module, _Fun, Args}}, State = #state{}) ->
  {Mod, Func, Args, Skipped, NewCommandStore} = find_cmd_and_get_updated_commands_in_transit(State, Id, From, To),
  do_exec_cmd(Mod, Func, Args),
  erlang:display(["exec_msg_cmd", "Id", Id, "From", From, "To", To, "Mod", Mod, "Func", Func, "Args", Args]),
  logger:info("exec_msg_cmd", #{what => exec_msg_cmd, id => Id,
                                from => From, to => To, skipped => Skipped,
                                mod => Mod, func => Func, args => Args}),
  {noreply, State#state{commands_in_transit = NewCommandStore}};
%%
%%
handle_cast({enable_to, {ProcPid, ProcPid, Module, Fun, Args = [{mil_timeout, MsgRef, _MsgContent}]}},
            State = #state{})
%% TODO: do not use MsgRef as ID later
  when not is_tuple(ProcPid)->
  Proc = pid_node(State, ProcPid),
  Bool_crashed = check_if_crashed(State, Proc) or check_if_crashed(State, Proc),
%%  Bool_whitelisted = check_if_whitelisted(From, To, Payload),
  if
    Bool_crashed ->
%%      still log this event for matching later on
      logger:info("enable_to_crsh", #{what => enable_to_crsh, id => State#state.id_counter,
        from => Proc, to => Proc, mod => Module, func => Fun, args => Args}),
      NextID = State#state.id_counter + 1,
      {noreply, State#state{id_counter = NextID}};  % if crashed, do also not let whitelisted trough
%%    Bool_whitelisted -> do_cast_cmd(State, FromPid, ToPid, Payload),
    {noreply, State};
    true ->
      QueueToUpdate = orddict:fetch(Proc, State#state.enabled_timeouts),
      UpdatedQueue = queue:in({MsgRef, Module, Fun, Args}, QueueToUpdate),
      UpdatedEnabledTimeouts = orddict:store(Proc, UpdatedQueue, State#state.enabled_timeouts),
      logger:info("enable_to", #{what => enable_to, id => MsgRef,
                from => Proc, to => Proc, mod => Module, func => Fun, args => Args}),
      erlang:display(["enable_to", "MsgRef", MsgRef, "From", Proc, "To", Proc, "Mod", Module, "Func", Fun, "Args", Args]),
      {noreply, State#state{enabled_timeouts = UpdatedEnabledTimeouts}}
  end;
%%
%%
handle_cast({disable_to, {ProcPid, MsgRef}}, State = #state{}) ->
  Proc = pid_node(State, ProcPid),
  {Skipped, NewEnabledTimeouts} = find_enabled_to_and_get_updated_to_in_transit(State, Proc, MsgRef),
  erlang:display(["disable_to", "Id", MsgRef, "From", Proc, "To", Proc]),
  logger:info("disable_to", #{what => disable_to, id => undefined,
    from => Proc, to => Proc, skipped => Skipped}),
  {noreply, State#state{enabled_timeouts = NewEnabledTimeouts}};
%%  {noreply, State};
%%
%%
handle_cast({bang, {FromPid, ToPid, Payload}}, State = #state{})
  when not is_tuple(ToPid)->
%%  erlang:display(["FromPid", FromPid, "ToPid", ToPid]),
  From = pid_node(State, FromPid),
  To = case is_pid(ToPid) of
         true -> pid_node(State, ToPid);
         _ -> ToPid
       end,
%%  erlang:display(["From", From, "To", To]),
  Bool_crashed = check_if_crashed(State, To) or check_if_crashed(State, From),
  Bool_whitelisted = check_if_whitelisted(From, To, Payload),
  if
    Bool_crashed ->
%%      still log this event for matching later on
      logger:info("rcv_crsh", #{what => rcv_crsh, id => State#state.id_counter, from => From, to => To, mesg => Payload}),
      NextID = State#state.id_counter + 1,
      {noreply, State#state{id_counter = NextID}};  % if crashed, do also not let whitelisted trough
    Bool_whitelisted -> do_send_msg(State, FromPid, ToPid, Payload),
                        {noreply, State};
    true ->
      QueueToUpdate = orddict:fetch({From, To}, State#state.messages_in_transit),
      UpdatedQueue = queue:in({State#state.id_counter, Payload}, QueueToUpdate),
      UpdatedMessagesInTransit = orddict:store({From, To}, UpdatedQueue, State#state.messages_in_transit),
      UpdatedNewMessagesInTransit = State#state.new_messages_in_transit ++ [{State#state.id_counter, From, To, Payload}],
      logger:info("received", #{what => received, id => State#state.id_counter, from => From, to => To, mesg => Payload}),
      NextID = State#state.id_counter + 1,
      {noreply, State#state{messages_in_transit = UpdatedMessagesInTransit,
        new_messages_in_transit = UpdatedNewMessagesInTransit,
        id_counter = NextID}}
  end;
%%
handle_cast({noop, {}}, State = #state{}) ->
  erlang:display("reach noop"),
  {noreply, State};
%%
handle_cast({send, {Id, From, To}}, State = #state{}) ->
  {M, Skipped, NewMessageStore} = find_message_and_get_updated_messages_in_transit(State, Id, From, To),
  do_send_msg(State, From, To, M),
  logger:info("snd_orig", #{what => snd_orig, id => Id, from => From, to => To, mesg => M, skipped => Skipped}),
  {noreply, State#state{messages_in_transit = NewMessageStore}};
%%
handle_cast({duplicate, {Id, From, To}}, State = #state{}) ->
  {M, Skipped} = find_message(State, Id, From, To),
  do_send_msg(State, From, To, M),
  logger:info("duplicat", #{what => duplicat, id => Id, from => From, to => To, mesg => M, skipped => Skipped}),
  {noreply, State};
%%
handle_cast({send_altered, {Id, From, To, New_payload}}, State = #state{}) ->
  {M, Skipped, NewMessageStore} = find_message_and_get_updated_messages_in_transit(State, Id, From, To),
  do_send_msg(State, From, To, New_payload),
  logger:info("snd_altr", #{what => snd_altr, id => Id, from => From, to => To, mesg => New_payload, old_mesg => M, skipped => Skipped}),
  {noreply, State#state{messages_in_transit = NewMessageStore}};
%%
handle_cast({drop, {Id, From, To}}, State = #state{}) ->
  {M, _, NewMessageStore} = find_message_and_get_updated_messages_in_transit(State, Id, From, To),
  logger:info("drop_msg", #{what => drop_msg, id => Id, from => From, to => To, mesg => M}),
%%  maybe check whether Skipped is empty and report if not
  {noreply, State#state{messages_in_transit = NewMessageStore}};
%%
handle_cast({client_req, {ClientName, Coordinator, ClientCmd}}, State = #state{}) ->
%%  TODO: once connected with application, submit the request to be executed by one of the clients; Coordinator is the node to contact
  gen_server:cast(client_pid(State, ClientName), {client_req, ClientName, Coordinator, ClientCmd}),
  logger:info("clnt_req", #{what => clnt_req, from => ClientName, to => Coordinator, mesg => ClientCmd}),
  {noreply, State};
%%
handle_cast({fwd_client_req, {ClientName, Coordinator, ClientCmd}}, State = #state{}) ->
%%  TODO: the client command should actually be the corresponding message
%%  TODO: what about ack's / replies?
  send_client_req(State, ClientName, Coordinator, ClientCmd),
%%  logged when issued
  {noreply, State};
%%
handle_cast({crash_trans, {NodeName}}, State = #state{}) ->
  UpdatedCrashTrans = sets:add_element(NodeName, State#state.transient_crashed_nodes),
  ListQueuesToEmpty = [{Other, NodeName} || Other <- get_all_node_names(State), Other /= NodeName],
  NewMessageStore = lists:foldl(fun({From, To}, SoFar) -> orddict:store({From, To}, queue:new(), SoFar) end,
              State#state.messages_in_transit,
              ListQueuesToEmpty),
%%  in order to let a schedule replay, we do not need to log all the dropped messages due to crashes
  logger:info("trans_crs", #{what => trns_crs, name => NodeName}),
  {noreply, State#state{transient_crashed_nodes = UpdatedCrashTrans, messages_in_transit = NewMessageStore}};
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
  NewMessageStore = lists:foldl(fun({From, To}, SoFar) -> orddict:erase({From, To}, SoFar) end,
    State#state.messages_in_transit,
    ListQueuesToDelete),
%%  in order to let a schedule replay, we do not need to log all the dropped messages due to crashes
  logger:info(#{what => perm_crs, name => NodeName}),
  {noreply, State#state{permanent_crashed_nodes = UpdatedCrashPerm, messages_in_transit = NewMessageStore}}.


%% TODO: only commands now
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

node_pid(State, Node) ->
  {ok, Pid} = orddict:find(Node, State#state.registered_nodes_pid),
  Pid.

pid_node(State, Pid) ->
  case orddict:find(Pid, State#state.registered_pid_nodes) of
    {ok, Node} -> Node;
    _ -> erlang:error(pid_not_registered)
  end.

client_pid(State, Node) ->
  {ok, Pid} = orddict:find(Node, State#state.client_nodes),
  Pid.

do_send_msg(State, From, To, Msg) ->
  gen_server:cast(node_pid(State, To), {message, node_pid(State, From), node_pid(State, To), Msg}).

send_client_req(State, From, To, Msg) ->
  gen_server:cast(To, {message, client_pid(State, From), node_pid(State, To), Msg}).

restart_timer() ->
%%  TODO: give option for this or scheduler asks for new events themself for?
  erlang:send_after(?INTERVAL, self(), trigger_get_events).

check_if_whitelisted(_From, _To, _Payload) ->
%%  TODO: implement whitelist check, currently none whitelisted
  false.

check_if_crashed(State, To) ->
  sets:is_element(To, State#state.transient_crashed_nodes) or sets:is_element(To, State#state.permanent_crashed_nodes).

get_all_node_names(State) ->
  orddict:fetch_keys(State#state.registered_nodes_pid).

find_id_in_queue(QueueToSearch, Id) ->
  find_id_in_queue([], QueueToSearch, Id).

find_id_in_queue(SkippedList, TailQueueToSearch, Id) ->
  {{value, {CurrentId, CurrentPayload}}, NewTailQueueToSearch} = queue:out(TailQueueToSearch),
  case CurrentId == Id  of
    true -> ReversedSkipped = lists:reverse(SkippedList),
            {CurrentPayload, ReversedSkipped, queue:join(queue:from_list(ReversedSkipped), NewTailQueueToSearch)};
%%    skipped does only contain the IDs
    false -> find_id_in_queue([CurrentId | SkippedList], NewTailQueueToSearch, Id)
%%  TODO: assumes that ID is in there
  end.

find_message_and_get_updated_messages_in_transit(State, Id, From, To) ->
  QueueToSearch = orddict:fetch({From, To}, State#state.messages_in_transit),
  {M, Skipped, UpdatedQueue} = find_id_in_queue(QueueToSearch, Id),
  NewMessageStore = orddict:store({From, To}, UpdatedQueue, State#state.messages_in_transit),
  {M, Skipped, NewMessageStore}.

find_message(State, Id, From, To) ->
  QueueToSearch = orddict:fetch({From, To}, State#state.messages_in_transit),
  {M, Skipped, _} = find_id_in_queue(QueueToSearch, Id),
  {M, Skipped}.

find_cmd_and_get_updated_commands_in_transit(State, Id, From, To) ->
  QueueToSearch = orddict:fetch({From, To}, State#state.commands_in_transit),
  {Mod, Func, Args, Skipped, UpdatedQueue} = find_cmd_id_in_queue(QueueToSearch, Id),
  NewCommandStore = orddict:store({From, To}, UpdatedQueue, State#state.commands_in_transit),
  {Mod, Func, Args, Skipped, NewCommandStore}.

do_exec_cmd(Mod, Func, Args) ->
  Result = erlang:apply(Mod, Func, Args),
  erlang:display(["Mod", Mod, "Func", Func, "Args", Args]),
  erlang:display(["Result, mil:395", Result]).

%% TODO: unify later again if things work

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

find_enabled_to_and_get_updated_to_in_transit(State, Proc, MsgRef) ->
  QueueToSearch = orddict:fetch(Proc, State#state.enabled_timeouts),
  {_, Skipped, UpdatedQueue} = find_to_in_queue(QueueToSearch, MsgRef), % we let MsgRef act as ID for timeouts (for now)
  NewEnabledTimeouts = orddict:store(Proc, UpdatedQueue, State#state.enabled_timeouts),
  {Skipped, NewEnabledTimeouts}.

find_to_in_queue(QueueToSearch, Id) ->
  find_to_in_queue([], QueueToSearch, Id).

find_to_in_queue(SkippedList, TailQueueToSearch, Ref) ->
  {{value, {CurrentRef, CurrentMod, CurrentFun, CurrentArgs}}, NewTailQueueToSearch} = queue:out(TailQueueToSearch),
  case CurrentRef == Ref  of
    true -> ReversedSkipped = lists:reverse(SkippedList),
      {CurrentRef, ReversedSkipped, queue:join(queue:from_list(ReversedSkipped), NewTailQueueToSearch)};
%%    skipped does only contain the IDs
    false -> find_id_in_queue([CurrentRef | SkippedList], NewTailQueueToSearch, Ref)
%%  TODO: assumes that ID is in there
  end.
