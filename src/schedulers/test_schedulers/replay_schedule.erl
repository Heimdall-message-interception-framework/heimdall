%%%-------------------------------------------------------------------
%%% @author fms
%%% @copyright (C) 2021, <COMPANY>
%%% @doc
%%% @end
%%%-------------------------------------------------------------------
-module(replay_schedule).
-include_lib("sched_event.hrl").

-behaviour(gen_server).

-export([start/1, start/2]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2,
  code_change/3]).

-define(SERVER, ?MODULE).
-define(INTERVAL, 200).

-record(state, {
    events_to_match = [], % currently list of sched_events for simplicity
    events_to_replay = [], % queue of sched_events
    enabled_events = orddict:new(), % map of enabled events: previous_id -> new_id
    encountered_unmatchable_event = false :: boolean(),
%%    messages_in_transit = [] :: [{ID::any(), From::pid(), To::pid(), Msg::any()}], % needed for backup scheduler
    commands_in_transit = [] :: [{ID::number(), From::pid(), To::pid(), Msg::any()}],
    backup_scheduler :: pid(),
    registered_nodes_pid = orddict:new() :: orddict:orddict(Name::atom(), pid())
}).

%%%===================================================================
%%% For External Use
%%%===================================================================

%%%===================================================================
%%% Spawning and gen_server implementation
%%%===================================================================

start(FileName) ->
  gen_server:start_link({local, ?SERVER}, ?MODULE, [FileName, undefined], []).

start(FileName, BackupScheduler) ->
  gen_server:start_link({local, ?SERVER}, ?MODULE, [FileName, BackupScheduler], []).

init([FileName, BackupScheduler]) ->
  {ok, Events} = file:consult(FileName),
%%  we distinguish events which need to be matched (receptions) and the ones which ought to be replayed
  {EventsToMatchList, EventsToReplayList} = lists:partition(fun(Ev) -> sched_event_functions:event_for_matching(Ev) end, Events),
  EventsToReplay = queue:from_list(EventsToReplayList),
  {ok, #state{events_to_match = EventsToMatchList, events_to_replay = EventsToReplay, backup_scheduler = BackupScheduler}}.

handle_call(_Request, _From, State = #state{}) ->
  {reply, ok, State}.

handle_cast({start}, State = #state{}) ->
  gen_server:cast(self(), {try_next}),
  {noreply, State};
%%
handle_cast({new_events, NewCommands}, State = #state{}) ->
  UpdatedCommands = State#state.commands_in_transit ++ NewCommands,
  case State#state.encountered_unmatchable_event of
    true -> {noreply, State#state{commands_in_transit = UpdatedCommands}};
    false ->
      CondFun = fun({From, To, Mod, Func, Args}) ->
                    (fun(Ev) ->
                      (Ev#sched_event.from == From) and (Ev#sched_event.to == To) and
                        (Ev#sched_event.mod == Mod) and (Ev#sched_event.func == Func) and
                        (Ev#sched_event.args == Args)
                     end)
                end,
      {NewEnabledEvents, NewEventsToMatch, SkippedEvent} =
        try % {NewEnabledEvents, NewEventsToMatch, SkippedEvent} =
          lists:foldl(
            fun({ID, From, To, Mod, Func, Args}, {EnabledEventsSoFar, EventsToMatchSoFar, _Skipped}) ->
              CondiFun = CondFun({From, To, Mod, Func, Args}),
              case msg_interception_helpers:remove_firstmatch(CondiFun, EventsToMatchSoFar) of
                {found, FoundEv, RemainingEventsToMatch} ->
                  {orddict:store(ID, FoundEv#sched_event.id, EnabledEventsSoFar), RemainingEventsToMatch, none_skipped};
                no_such_element ->
  %%                here skipped is the first message without a corresponding match
  %%                erlang:display({ID, From, To, Mod, Func, Args}),
  %%                erlang:display({EventsToMatchSoFar}),
                  throw({skipped, {EnabledEventsSoFar, EventsToMatchSoFar, {skipped, {ID, From, To, Mod, Func, Args}}}})
              end
            end,
            {State#state.enabled_events, State#state.events_to_match, none_skipped},
            NewCommands)
        catch
          throw:{skipped, {Value}} -> Value
        end,
      case SkippedEvent of
        none_skipped -> NewEncounteredUnmatchable = false;
        {skipped, _} -> NewEncounteredUnmatchable = true
      end,
      notify(),
      {noreply, State#state{commands_in_transit = UpdatedCommands,
        enabled_events = NewEnabledEvents,
        events_to_match = NewEventsToMatch,
        encountered_unmatchable_event = NewEncounteredUnmatchable}}
  end;
%%
handle_cast({try_next}, State = #state{}) ->
%%  TODO: currently, next signal for try_next a bit redundant
  case queue:out(State#state.events_to_replay) of
    {empty, _} -> {noreply, State};
    {{value, NextEvent}, TempEventsToReplay} ->
      NewRegisteredNodesPid = case NextEvent#sched_event.what of
                                reg_node ->
                                  {ok, Pid} = (NextEvent#sched_event.class):start(NextEvent#sched_event.name),
                                  orddict:store(NextEvent#sched_event.name, Pid, State#state.registered_nodes_pid);
                                _ -> State#state.registered_nodes_pid
                              end,
      {NewCommandsInTransit, MatchableEnabled} =
        case orddict:is_key(NextEvent#sched_event.id, State#state.enabled_events) of
          true ->
            {ok, MatchedID} = orddict:find(NextEvent#sched_event.id, State#state.enabled_events),
            case NextEvent#sched_event.what of
              exec_msg_cmd -> cast_cmd_and_notify(NextEvent);
              snd_altr -> cast_cmd_and_notify(NextEvent);
              drop_msg -> cast_cmd_and_notify(NextEvent);
              duplicat -> cast_cmd_and_notify(NextEvent);
              _ -> throw("replay_schedule:130: How can this happen?")
            end,
            {found, _, TempMessagesInTransit} = msg_interception_helpers:remove_firstmatch(
                          fun({Id, _, _, _, _, _}) -> Id == MatchedID end, State#state.commands_in_transit),
            {TempMessagesInTransit, true};
          false ->
            case NextEvent#sched_event.what of
              trns_crs ->
                  TempMessagesInTransit = lists:filter(fun({_, _, To, _}) -> To /= NextEvent#sched_event.name end, State#state.commands_in_transit),
                {TempMessagesInTransit, true};
              _ ->  {State#state.commands_in_transit, false}
              end
        end,
      OtherEnabled =
        case NextEvent#sched_event.what of
          reg_node ->
%%            this one has already been started but needs to be registered
            {ok, PidNew} = orddict:find(NextEvent#sched_event.name, NewRegisteredNodesPid),
            cast_cmd_and_notify(NextEvent, PidNew),
            true;
%%          reg_clnt ->
%%            cast_cmd_and_notify({register_client, {client1}}),
%%            true;
%%          clnt_req ->
%%            cast_cmd_and_notify({client_req, {NextEvent#sched_event.from, NextEvent#sched_event.to, NextEvent#sched_event.mesg}}),
%%            true;
          trns_crs ->
            cast_cmd_and_notify(NextEvent),
            true;
          rejoin ->
            cast_cmd_and_notify(NextEvent),
            true;
          perm_crs ->
            cast_cmd_and_notify(NextEvent),
            true;
          _ -> false
        end,
%%  if successful, try another round; if not wait for new events
    NewEventsToReplay =
      case MatchableEnabled or OtherEnabled of
        false -> case State#state.encountered_unmatchable_event of
                   true -> gen_server:cast(self(), {start_backup_scheduler});
                   false -> erlang:send_after(?INTERVAL, self(), trigger_get_events)
                 end,
                 State#state.events_to_replay;
        true -> notify(),
                TempEventsToReplay
      end,
      {noreply, State#state{commands_in_transit = NewCommandsInTransit,
        events_to_replay = NewEventsToReplay,
        registered_nodes_pid = NewRegisteredNodesPid}}
  end;
%%
handle_cast({start_backup_scheduler}, State = #state{}) ->
%%  for now, we assume that a scheduler only needs the currently enabled events and no info about the past
%%  TODO: send messages_in_transit
  {noreply, State}.


handle_info(_Info, State = #state{}) ->
  {noreply, State}.

terminate(_Reason, _State = #state{}) ->
  ok.

code_change(_OldVsn, State = #state{}, _Extra) ->
  {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

cast_cmd_and_notify(NextEvent, PidNew) ->
  message_interception_layer:register_with_name(NextEvent#sched_event.name, PidNew, NextEvent#sched_event.class),
  notify().

cast_cmd_and_notify(NextEvent) ->
%%  TODO: call the respective methods here!
  ID = NextEvent#sched_event.id,
  From = NextEvent#sched_event.from,
  To = NextEvent#sched_event.to,
  Module = NextEvent#sched_event.mod,
  Func = NextEvent#sched_event.func,
  Args = NextEvent#sched_event.args,
  Name = NextEvent#sched_event.name,
  case NextEvent#sched_event.what of
      exec_msg_cmd ->
        message_interception_layer:exec_msg_command(ID, From, To, Module, Func, Args);
%%    TODO: add timeout behaviour
      enable_to -> ok;
      enable_to_crsh -> ok;
      disable_to -> ok;
      duplicat ->
        message_interception_layer:duplicate_msg_command(ID, From, To);
      snd_altr ->
        message_interception_layer:alter_msg_command(ID, From, To, Args);
      drop_msg ->
        message_interception_layer:drop_msg_command(ID, From, To);
      trns_crs ->
        message_interception_layer:transient_crash(Name);
      rejoin ->
        message_interception_layer:rejoin(Name);
      perm_crs ->
        message_interception_layer:permanent_crash(Name)
  end,
  notify().

notify() ->
  gen_server:cast(self(), {try_next}).
