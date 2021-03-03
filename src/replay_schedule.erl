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
    events_to_match = [], % currently list of sched_events for simplicity % TODO: turn into orddict (From, To) with queues of sched_events
    events_to_replay = [], % queue of sched_events
    enabled_events = orddict:new(), % map of enabled events: previous_id -> new_id
    encountered_unmatchable_event = false :: boolean(),
    messages_in_transit = [] :: [{ID::any(), From::pid(), To::pid(), Msg::any()}], % needed for backup scheduler
    backup_scheduler :: pid(),
    message_interception_layer_id :: pid() | undefined,
    registered_nodes_pid = orddict:new() :: orddict:orddict(Name::atom(), pid())
}).

%%%===================================================================
%%% Spawning and gen_server implementation
%%%===================================================================

start(FileName) ->
  gen_server:start_link({local, ?SERVER}, ?MODULE, [FileName, undefined], []).

start(FileName, BackupScheduler) ->
  gen_server:start_link({local, ?SERVER}, ?MODULE, [FileName, BackupScheduler], []).

init([FileName, BackupScheduler]) ->
  {ok, Events} = file:consult(FileName),
  {EventsToMatchList, EventsToReplayList} = lists:partition(fun(Ev) -> sched_event_functions:event_for_matching(Ev) end, Events),
  EventsToReplay = queue:from_list(EventsToReplayList),
  {ok, #state{events_to_match = EventsToMatchList, events_to_replay = EventsToReplay, backup_scheduler = BackupScheduler}}.

handle_call(_Request, _From, State = #state{}) ->
  {reply, ok, State}.

handle_cast({start}, State = #state{}) ->
  gen_server:cast(self(), {try_next}),
  {noreply, State};
%%
handle_cast({new_events, ListNewMessages}, State = #state{}) ->
%%  TODO: change to pulling for new events if going for this option
  UpdatedMessages = State#state.messages_in_transit ++ ListNewMessages,
  case State#state.encountered_unmatchable_event of
    true -> {noreply, State#state{messages_in_transit = UpdatedMessages}};
    false ->
      CondFun = fun({From, To, Msg}) -> (fun(Ev) -> (Ev#sched_event.from == From) and (Ev#sched_event.to == To) and (Ev#sched_event.mesg == Msg) end) end,
      {NewEnabledEvents, NewEventsToMatch, SkippedEvent} =
        try % {NewEnabledEvents, NewEventsToMatch, SkippedEvent} =
          lists:foldl(fun({ID, From, To, Msg}, {EnabledEventsSoFar, EventsToMatchSoFar, _Skipped}) ->
            CondiFun = CondFun({From, To, Msg}),
            case helper_functions:firstmatch(CondiFun, EventsToMatchSoFar) of
              {found, FoundEv, RemainingEventsToMatch} ->
                {orddict:store(ID, FoundEv#sched_event.id, EnabledEventsSoFar), RemainingEventsToMatch, none_skipped};
              no_such_element ->
%%                here skipped is the first message without a corresponding match
                erlang:display({ID, From, To, Msg}),
                erlang:display({EventsToMatchSoFar}),
                throw({skipped, {EnabledEventsSoFar, EventsToMatchSoFar, {skipped, {ID, From, To, Msg}}}})
            end
                      end,
            {State#state.enabled_events, State#state.events_to_match, none_skipped},
            ListNewMessages)
        catch
          throw:{skipped, {Value}} -> Value
        end,
      case SkippedEvent of
        none_skipped -> NewEncounteredUnmatchable = false;
        {skipped, _} -> NewEncounteredUnmatchable = true
      end,
      gen_server:cast(self(), {try_next}),
      {noreply, State#state{messages_in_transit = UpdatedMessages,
        enabled_events = NewEnabledEvents,
        events_to_match = NewEventsToMatch,
        encountered_unmatchable_event = NewEncounteredUnmatchable}}
  end;
%%
handle_cast({register_message_interception_layer, MIL}, State = #state{}) ->
  {noreply, State#state{message_interception_layer_id = MIL}};
%%
handle_cast({try_next}, State = #state{}) ->
%%  TODO: currently, next signal for try_next a bit redundant
  case queue:out(State#state.events_to_replay) of
    {empty, _} -> {noreply, State};
    {{value, NextEvent}, TempEventsToReplay} ->
      MIL = State#state.message_interception_layer_id,
      NewRegisteredNodesPid = case NextEvent#sched_event.what of
                                reg_node ->
                                  {ok, Pid} = (NextEvent#sched_event.class):start(NextEvent#sched_event.name, MIL),
                                  orddict:store(NextEvent#sched_event.name, Pid, State#state.registered_nodes_pid);
                                _ -> State#state.registered_nodes_pid
                              end,
      {NewMessagesInTransit, MatchableEnabled} =
        case orddict:is_key(NextEvent#sched_event.id, State#state.enabled_events) of
          true ->
            {ok, MatchedID} = orddict:find(NextEvent#sched_event.id, State#state.enabled_events),
            case NextEvent#sched_event.what of
              snd_orig ->
                cast_msg_and_notify(MIL, {send, {MatchedID, NextEvent#sched_event.from, NextEvent#sched_event.to}});
              snd_altr ->
                cast_msg_and_notify(MIL, {send_altered, {MatchedID, NextEvent#sched_event.from, NextEvent#sched_event.to, NextEvent#sched_event.mesg}});
              drop_msg ->
                cast_msg_and_notify(MIL, {drop, {MatchedID, NextEvent#sched_event.from, NextEvent#sched_event.to}})
            end,
            {found, _, TempMessagesInTransit} = helper_functions:firstmatch(fun({Id, _, _, _}) -> Id == MatchedID end, State#state.messages_in_transit),
            {TempMessagesInTransit, true};
          false ->
            case NextEvent#sched_event.what of
              trns_crs ->
                  TempMessagesInTransit = lists:filter(fun({_, _, To, _}) -> To /= NextEvent#sched_event.name end, State#state.messages_in_transit),
                {TempMessagesInTransit, true};
              _ ->  {State#state.messages_in_transit, false}
              end
        end,
      OtherEnabled =
        case NextEvent#sched_event.what of
          cast_msg ->
            {From, To, Mesg} = {NextEvent#sched_event.from, NextEvent#sched_event.to, NextEvent#sched_event.mesg},
            cast_msg_and_notify(MIL, {cast_msg, From, To, Mesg}),
            true;
          reg_node ->
            {ok, PidNew} = orddict:find(NextEvent#sched_event.name, NewRegisteredNodesPid),
            cast_msg_and_notify(MIL, {register, {NextEvent#sched_event.name, PidNew, NextEvent#sched_event.class}}),
            true;
          reg_clnt ->
            cast_msg_and_notify(MIL, {register_client, {client1}}),
            true;
          clnt_req ->
            cast_msg_and_notify(MIL, {client_req, {NextEvent#sched_event.from, NextEvent#sched_event.to, NextEvent#sched_event.mesg}}),
            true;
          trns_crs ->
            cast_msg_and_notify(MIL, {crash_trans, {NextEvent#sched_event.name}}),
            true;
          rejoin ->
            cast_msg_and_notify(MIL, {rejoin, {NextEvent#sched_event.name}}),
            true;
          perm_crs ->
            cast_msg_and_notify(MIL, {crash_perm, {NextEvent#sched_event.name}}),
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
        true -> gen_server:cast(self(), {try_next}),
                TempEventsToReplay
      end,
      {noreply, State#state{messages_in_transit = NewMessagesInTransit,
        events_to_replay = NewEventsToReplay,
        registered_nodes_pid = NewRegisteredNodesPid}}
  end;
%%
handle_cast({start_backup_scheduler}, State = #state{}) ->
%%  for now, we assume that a scheduler only needs the currently enabled events and no info about the past
%%  TODO: send messages_in_transit, register MIL and start it
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

cast_msg_and_notify(To, Message) ->
  gen_server:cast(To, Message),
  gen_server:cast(self(), {try_next}).
