%%%-------------------------------------------------------------------
%%% @author research
%%% @copyright (C) 2021, <COMPANY>
%%% @doc
%%%
%%% @end
%%% Created : 25. Oct 2021 16:09
%%%-------------------------------------------------------------------
-module(online_chain_covering).
-author("research").

-behaviour(gen_server).

%% API
-export([start_link/0, start/1, add_events/2, get_first/2, get_all_ids_in_chains/1]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2,
  code_change/3]).

-define(SERVER, ?MODULE).

-record(state, {
  next_chain_key = 1 :: integer(),
  next_chain_container = 1 :: integer(),
  last_chain_container = undefined :: integer() | undefined,
  last_chain_key = undefined :: integer() | undefined,
  last_predecessors = sets:new() :: sets:set(any()),
  did_use_one_since_adding = true :: boolean(),
  % when we add events w/o get_first in between, a non-sched event was fired and we waive the last predecessors
  chain_map = maps:new() :: #{integer() =>
                                    #{integer() => queue:queue({any(), sets:set(any())})}},
                                    % store cmd ids and predecessors
  command_ids_in_chains = sets:new() :: sets:set(any()),
  last_events = maps:new() :: #{integer() => any()}
}).

%%%===================================================================
%%% API
%%%===================================================================

%% @doc Spawns the server and registers the local name (unique)
-spec(start_link() ->
  {ok, Pid :: pid()} | ignore | {error, Reason :: term()}).
start_link() ->
  gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

start(_Config) ->
  gen_server:start({local, ?MODULE}, ?MODULE, [], []).

add_events(OCC, CommInTransit) ->
  gen_server:call(OCC, {add_events, CommInTransit}).

get_first(OCC, ChainKey) ->
  gen_server:call(OCC, {get_first, ChainKey}).

get_all_ids_in_chains(OCC) ->
  gen_server:call(OCC, {get_all_ids_in_chains}).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

%% @private
%% @doc Initializes the server
-spec(init(Args :: term()) ->
  {ok, State :: #state{}} | {ok, State :: #state{}, timeout() | hibernate} |
  {stop, Reason :: term()} | ignore).
init([]) ->
  {ok, #state{}}.

%% @private
%% @doc Handling call messages
-spec(handle_call(Request :: term(), From :: {pid(), Tag :: term()},
    State :: #state{}) ->
  {reply, Reply :: term(), NewState :: #state{}} |
  {reply, Reply :: term(), NewState :: #state{}, timeout() | hibernate} |
  {noreply, NewState :: #state{}} |
  {noreply, NewState :: #state{}, timeout() | hibernate} |
  {stop, Reason :: term(), Reply :: term(), NewState :: #state{}} |
  {stop, Reason :: term(), NewState :: #state{}}).
handle_call({add_events, CommInTrans}, _From,
    State = #state{command_ids_in_chains = IDsInChains, did_use_one_since_adding = FlagUseAfterAdding}) ->
%%  0) set last predecessors to empty set if not used another sched command since adding last
  State1 = case FlagUseAfterAdding of
             true -> State;
             false -> LastPreds1 = sets:new(),
               State#state{last_predecessors = LastPreds1}
           end,
%%  1a) single out commands which are not in chain covering yet (maybe store ids in a set but keep consistent)
  AddedCommands = detect_added_commands_in_transit(IDsInChains, CommInTrans),
%%  1b) partition them by receiver since they go in the same chain
  % get all recipients
  RecipientsListUnique = remove_dups(lists:reverse(
    lists:foldl(fun({_, _, To, _, _, _}, AccListRev) -> [To | AccListRev] end, [], AddedCommands)
  )),
  % per recipient, construct a list of commands
  AddedCommandsByReceiver = lists:map(
    fun(Recipient) -> lists:filter(fun({_, _, To, _, _, _}) -> To == Recipient end, AddedCommands) end,
    RecipientsListUnique
  ),
  StrippedCommandsByReceiver = lists:map(
    fun(ListCmd) -> [ID || {ID, _, _, _, _, _} <- ListCmd] end,
    AddedCommandsByReceiver),
%%  2) for each command, insert it to chains
%%  2a) for the first in list, use the chain from which we took the last event (cannot have other events as just happened)
  {State2, RemainingCommandLists, ChainKeysAffected} =
    insert_first_into_last_chain_if_applicable(StrippedCommandsByReceiver, State1),
%%  2b) for the remaining lists, check whether we can insert them in old ones one list by another
  {State3, ChainKeysAffected1} = lists:foldl(
    fun(CmdList, {StateAcc, ChainKeysAffectedAcc}) ->
      insert_into_some_container(CmdList, ChainKeysAffectedAcc, StateAcc) end,
    {State2, ChainKeysAffected},
    RemainingCommandLists
  ),
%%  3) update (remaining) state
  StrippedAddedCommandsSet = sets:from_list([ID || {ID, _, _, _, _, _} <- AddedCommands]),
  FlagUseAfterAdding1 = case sets:is_empty(StrippedAddedCommandsSet) of
                          true -> FlagUseAfterAdding; % haven't added anything so as previous
                          false -> false
                        end,
  State4 = State3#state{
    command_ids_in_chains = sets:union(IDsInChains, StrippedAddedCommandsSet),
    did_use_one_since_adding = FlagUseAfterAdding1
  },
%%  4) check that commands in transit and ids in OCC match
  IDsInChains1 = State4#state.command_ids_in_chains,
  StrippedCommandsSet = sets:from_list([ID || {ID, _, _, _, _, _} <- CommInTrans]),
  case (sets:is_subset(StrippedCommandsSet, IDsInChains1) and
        sets:is_subset(IDsInChains1, StrippedCommandsSet)) of
    false -> erlang:display(["CommInTrans", sets:to_list(StrippedCommandsSet), "IDsInChains1", sets:to_list(IDsInChains1)]),
      erlang:throw("comm in trans and ids in chains do not match");
    true -> ok
  end,
  {reply, ChainKeysAffected1, State4};
handle_call({get_first, ChainKey}, _From,
    State = #state{chain_map = ChainMap, last_events = LastEvents, command_ids_in_chains = IDsInChains}) ->
%%  0) set flag that we used one since last adding commands
  State1 = State#state{did_use_one_since_adding = true},
  {ContainerIndex, Chain} = get_container_and_chain_for_key(ChainKey, ChainMap),
  case queue:out(Chain) of
    {{value, {ID, Preds}}, Chain1} ->
      Reply = {found, ID},
      % update ChainMap
      Container = maps:get(ContainerIndex, ChainMap),
      Container1 = maps:update(ChainKey, Chain1, Container),
      ChainMap1 = maps:update(ContainerIndex, Container1, ChainMap),
      % update last event from chainkey, only used when chain is empty
      LastEvents1 = maps:put(ChainKey, ID, LastEvents),
      IDsInChains1 = sets:del_element(ID, IDsInChains),
      Preds1 = sets:add_element(ID, Preds),
      State2 = State1#state{chain_map = ChainMap1,
        last_chain_key = ChainKey,
        last_chain_container = ContainerIndex,
        last_predecessors = Preds1,
        last_events = LastEvents1,
        command_ids_in_chains = IDsInChains1,
        did_use_one_since_adding = true
        },
      {reply, Reply, State2};
    {empty, _} ->
      {reply, empty, State1}
  end;
handle_call({get_all_ids_in_chains}, _From,
    State = #state{command_ids_in_chains = IDsInChains}) ->
  IDsInChainsList = sets:to_list(IDsInChains),
  {reply, IDsInChainsList, State};
handle_call(_Request, _From, State = #state{}) ->
  erlang:throw("unhandled call"),
  {reply, ok, State}.

%% @private
%% @doc Handling cast messages
-spec(handle_cast(Request :: term(), State :: #state{}) ->
  {noreply, NewState :: #state{}} |
  {noreply, NewState :: #state{}, timeout() | hibernate} |
  {stop, Reason :: term(), NewState :: #state{}}).
handle_cast(_Request, State = #state{}) ->
  {noreply, State}.

%% @private
%% @doc Handling all non call/cast messages
-spec(handle_info(Info :: timeout() | term(), State :: #state{}) ->
  {noreply, NewState :: #state{}} |
  {noreply, NewState :: #state{}, timeout() | hibernate} |
  {stop, Reason :: term(), NewState :: #state{}}).
handle_info(_Info, State = #state{}) ->
  {noreply, State}.

%% @private
%% @doc This function is called by a gen_server when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any
%% necessary cleaning up. When it returns, the gen_server terminates
%% with Reason. The return value is ignored.
-spec(terminate(Reason :: (normal | shutdown | {shutdown, term()} | term()),
    State :: #state{}) -> term()).
terminate(_Reason, _State = #state{}) ->
  ok.

%% @private
%% @doc Convert process state when code is changed
-spec(code_change(OldVsn :: term() | {down, term()}, State :: #state{},
    Extra :: term()) ->
  {ok, NewState :: #state{}} | {error, Reason :: term()}).
code_change(_OldVsn, State = #state{}, _Extra) ->
  {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

detect_added_commands_in_transit(CommInChains, CommInTrans) ->
  HelperPredicate = fun({ID, _, _, _, _, _}) -> (not sets:is_element(ID, CommInChains)) end,
  lists:filter(HelperPredicate, CommInTrans).

insert_first_into_last_chain_if_applicable(AddedCommandsByReceiver,
    State = #state{last_chain_container = LastContainer, last_chain_key = LastChainKey,
                   chain_map = ChainMap, last_predecessors = LastPreds, did_use_one_since_adding = FlagUseAfterAdding})
  when (AddedCommandsByReceiver /= []) and FlagUseAfterAdding -> % when used after adding still valid attempt
  case {LastContainer, LastChainKey} of
      {undefined, _} -> {State, AddedCommandsByReceiver, []};
      {_, undefined} -> {State, AddedCommandsByReceiver, []};
      {_ActualChainKey, _ActualLastChainKey} ->
        [FirstCommandList | RemCommandsList] = AddedCommandsByReceiver,
        % retrieve chain and check whether it is empty
        Container = maps:get(LastContainer, ChainMap),
        Chain = maps:get(LastChainKey, Container),
        case queue:is_empty(Chain) of
          true -> % add the first list of commands
            PairedCmdsAndPreds = paired_list_cmds_with_preds(FirstCommandList, LastPreds),
            Chain1 = queue:from_list(PairedCmdsAndPreds),
            ChainContainer1 = maps:update(LastChainKey, Chain1, Container),
            ChainMap1 = maps:update(LastContainer, ChainContainer1, ChainMap),
            State1 = State#state{chain_map = ChainMap1},
            {State1, RemCommandsList,
              lists:duplicate(length(FirstCommandList), LastChainKey)};
          false -> % do not add them since they are concurrent, they cannot be dependent
            {State, AddedCommandsByReceiver, []}
        end
    end;
insert_first_into_last_chain_if_applicable(AddedCommandsByReceiver,
    State = #state{did_use_one_since_adding = _FlagUseAfterAdding}) ->
%%  when AddedCommandsByReceiver == [] or not FlagUseAfterAdding ->
  {State, AddedCommandsByReceiver, []}.

  insert_into_some_container(CmdList, ChainKeysAffected, State) ->
  % iterate over chainmap and check whether there is either some chain in container to append or space
  SortedIndices = lists:sort(maps:keys(State#state.chain_map)),
  {State1, ChainKeysAffectedNew} =
    recursively_insert_into_some_container(SortedIndices, CmdList, State),
  ChainKeysAffected1 = lists:append(ChainKeysAffected, ChainKeysAffectedNew),
  {State1, ChainKeysAffected1}.

recursively_insert_into_some_container([], CmdList,
    State = #state{chain_map = ChainMap, next_chain_key = NextChainKey, last_predecessors = LastPreds}) ->
    % add new chain_container
      NextContainerIndex = State#state.next_chain_container,
      PairedCmdAndPreds = paired_list_cmds_with_preds(CmdList, LastPreds),
      NewContainer = maps:from_list([{NextChainKey, queue:from_list(PairedCmdAndPreds)}]),
      ChainMap1 = maps:put(NextContainerIndex, NewContainer, ChainMap),
      State1 = State#state{
        next_chain_container = NextContainerIndex + 1,
        next_chain_key = NextChainKey + 1,
        chain_map = ChainMap1
      },
      ChainKeysAffectedNew = lists:duplicate(length(CmdList), NextChainKey),
      {State1, ChainKeysAffectedNew};
recursively_insert_into_some_container([ContainerIndex | RemIndices], CmdList,
    State = #state{chain_map = ChainMap}) ->
      Container = maps:get(ContainerIndex, ChainMap),
      case insert_into_container(Container, ContainerIndex, CmdList, State) of
        full_container ->
          recursively_insert_into_some_container(RemIndices, CmdList, State);
        {ChainKeyUpdated, ChainUpdated, ContainerWOUpdChain, NextChainKeyUpd} ->
          ChainMap2 = case ContainerIndex == 1 of
                        true -> % no need swap, so insert back and return
                          Container1 = maps:put(ChainKeyUpdated, ChainUpdated, ContainerWOUpdChain),
                          maps:update(1, Container1, ChainMap); % ContainerIndex==1
                        false -> % need to swap
                          LastContainerIndex = ContainerIndex - 1,
                          LastContainer = maps:get(LastContainerIndex, ChainMap),
                          % add UpdatedChain to last container
                          LastContainer1 = maps:put(ChainKeyUpdated, ChainUpdated, LastContainer),
                          % assign both containers new indices in chain_map
                          ChainMap3 = maps:update(LastContainerIndex, ContainerWOUpdChain, ChainMap),
                          maps:update(ContainerIndex, LastContainer1, ChainMap3)
                      end,
          State1 = State#state{chain_map = ChainMap2, next_chain_key = NextChainKeyUpd},
          ChainKeysAffectedNew = lists:duplicate(length(CmdList), ChainKeyUpdated),
          {State1, ChainKeysAffectedNew}
      end.

insert_into_container(Container, MaxContainerSize, CmdList,
    State = #state{last_predecessors = LastPreds, last_events = LastEvents}) ->
%% returns {ChainKeyUpdated, ChainUpdated, ContainerWOUpdChain}
  % 1) check whether we can add and do if so
  SortedKeys = lists:sort(maps:keys(Container)),
  case recursively_insert_into_chain(SortedKeys, CmdList, Container, LastPreds, LastEvents) of
    checked_all_chains -> % did not find chain to insert so 2) new chain if possible
      case length(SortedKeys) < MaxContainerSize of
        true -> % can insert new chain
          NextChainKey = State#state.next_chain_key,
          CmdListToInsert = paired_list_cmds_with_preds(CmdList, LastPreds),
          ChainUpdated = queue:from_list(CmdListToInsert),
          {NextChainKey, ChainUpdated, Container, NextChainKey+1}; % new chain
        false -> % cannot insert new chain
          full_container
      end;
    {ChainKeyUpdated, ChainUpdated} -> Container1 = maps:remove(ChainKeyUpdated, Container),
      {ChainKeyUpdated, ChainUpdated, Container1, State#state.next_chain_key} % chain existed
  end.


recursively_insert_into_chain([], _CmdList, _Container, _LastPreds, _LastEvents) ->
      checked_all_chains;
recursively_insert_into_chain([ChainKey | RemKeys], CmdList, Container, LastPreds, LastEvents) ->
      Chain = maps:get(ChainKey, Container),
%%    get the "last" element of chain (may have been executed)
      LastInChain =
        case queue:is_empty(Chain) of
          true ->
            case maps:get(ChainKey, LastEvents, undefined) of
              undefined ->
                erlang:throw("existing chain without previous id...");
%%                recursively_insert_into_chain(RemKeys, CmdList, Container, LastPreds, LastEvents);
              LastID -> LastID
            end;
          false -> queue:daeh(Chain)
        end,
      case sets:is_element(LastInChain, LastPreds) of
        true -> % can insert
          CmdListToInsert = paired_list_cmds_with_preds(CmdList, LastPreds),
          Chain1 = queue:from_list(lists:append(queue:to_list(Chain), CmdListToInsert)),
          {ChainKey, Chain1};
        false -> % cannot insert so recurse
          recursively_insert_into_chain(RemKeys, CmdList, Container, LastPreds, LastEvents)
      end.

remove_dups([])    -> [];
remove_dups([H|T]) -> [H | [X || X <- remove_dups(T), X /= H]].

get_container_and_chain_for_key(ChainKey, ChainMap) ->
  ContainerIndices = maps:keys(ChainMap),
  rec_get_container_and_chain_for_key(ContainerIndices, ChainKey, ChainMap).

rec_get_container_and_chain_for_key([], _ChainKey, _ChainMap) ->
  erlang:throw("requesting chain for unknown key");
rec_get_container_and_chain_for_key([Index | RemIndices], ChainKey, ChainMap) ->
  Container = maps:get(Index, ChainMap),
  case maps:get(ChainKey, Container, notfound) of
    notfound -> rec_get_container_and_chain_for_key(RemIndices, ChainKey, ChainMap);
    Chain -> {Index, Chain}
  end.

paired_list_cmds_with_preds(CommandList, LastPreds) ->
  ListPreds = lists:duplicate(length(CommandList), LastPreds),
  lists:zip(CommandList, ListPreds).