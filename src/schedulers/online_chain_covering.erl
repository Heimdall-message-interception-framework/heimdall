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
-export([start_link/0, start/1, add_events/2, get_first/2]).

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
  chain_map = maps:new() :: maps:map(integer(),
                                    maps:map(integer(), queue:queue({any(), sets:set(any())}))),
                                    % store cmd ids and predecessors
  command_ids_in_chains = sets:new() :: sets:set(any()),
  last_events = maps:new() :: maps:map(integer())
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
    State = #state{command_ids_in_chains = IDsInChains}) ->
%%  1a) single out commands which are not in chain covering yet (maybe store ids in a set but keep consistent)
  AddedCommands = detect_added_commands_in_transit(IDsInChains, CommInTrans),
%%  1b) partition them by receiver since they go in the same chain
  % get all recipients
  RecipientsListUnique = remove_dups(lists:reverse(
    lists:foldl(fun({_, _, To, _, _, _}, AccListRev) -> [To | AccListRev] end, [], AddedCommands)
  )),
  erlang:display(["AddedCommands", AddedCommands]),
  erlang:display(["RecipientsListUnique", RecipientsListUnique]),
  % per recipient, construct a list of commands
  AddedCommandsByReceiver = lists:map(
    fun(Recipient) -> lists:filter(fun({_, _, To, _, _, _}) -> To == Recipient end, AddedCommands) end,
    RecipientsListUnique
  ),
  erlang:display(["AddedCommandsByRcv", AddedCommandsByReceiver]),
  StrippedCommandsByReceiver = lists:map(
    fun(ListCmd) -> [ID || {ID, _, _, _, _, _} <- ListCmd] end,
    AddedCommandsByReceiver),
  erlang:display(["StrippedCommandsByReceiver", StrippedCommandsByReceiver]),
%%  2) for each command, insert it to chains
%%  2a) for the first in list, use the chain from which we took the last event (cannot have other events as just happened)
  {State1, RemainingCommandLists, ChainKeysAffected} =
    insert_first_into_last_chain_if_applicable(StrippedCommandsByReceiver, State),
%%  2b) for the remaining lists, check whether we can insert them in old ones one list by another
  {State2, ChainKeysAffected1} = lists:foldl(
    fun(CmdList, {StateAcc, ChainKeysAffectedAcc}) ->
      insert_into_some_container(CmdList, ChainKeysAffectedAcc, StateAcc) end,
    {State1, ChainKeysAffected},
    RemainingCommandLists
  ),
%%  3) update (remaining) state
  State3 = State2#state{
    command_ids_in_chains = sets:union(IDsInChains, sets:from_list(AddedCommands))
  },
  {reply, ChainKeysAffected1, State3};
handle_call({get_first, ChainKey}, _From, State = #state{chain_map = ChainMap, last_events = LastEvents}) ->
  {ContainerIndex, Chain} = get_container_and_chain_for_key(ChainKey, ChainMap),
  case queue:out(Chain) of
    {{value, {ID, Preds}}, Chain1} ->
      Reply = {found, ID},
      % update ChainMap
      Container = maps:get(ContainerIndex, ChainMap),
      Container1 = maps:update(ChainKey, Chain1, Container),
      ChainMap1 = maps:update(ContainerIndex, Container1, ChainMap),
      % update last event from chainkey
      LastEvents1 = maps:put(ChainKey, ID, LastEvents),
      State1 = State#state{chain_map = ChainMap1,
        last_chain_key = ChainKey,
        last_predecessors = Preds,
        last_events = LastEvents1},
      {reply, Reply, State1};
    {empty, _} ->
      {reply, empty, State}
  end;
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
  HelperPredicate = fun(ID) -> (not sets:is_element(ID, CommInChains)) end,
  lists:filter(HelperPredicate, CommInTrans).

insert_first_into_last_chain_if_applicable(AddedCommandsByReceiver,
    State = #state{last_chain_container = LastContainer, last_chain_key = LastChainKey,
                   chain_map = ChainMap, last_predecessors = LastPreds}) ->
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
          false -> % do not add them since they are concurrent
            {State, AddedCommandsByReceiver, []}
        end
    end.

insert_into_some_container(CmdList, ChainKeysAffected, State) ->
  % iterate over chainmap and check whether there is either some chain in container to append or space
  SortedIndices = lists:sort(maps:keys(State#state.chain_map)),
  {State1, ChainKeysAffectedNew} =
    recursively_insert_into_some_container(SortedIndices, CmdList, State),
%%  erlang:display(["ChainKeysAffectedPrev", ChainKeysAffected, "ChainKeysAffectedNew", ChainKeysAffectedNew]),
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
%%      erlang:display(["ChainKeysAffected new container", ChainKeysAffectedNew]),
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
                          maps:update(ChainKeyUpdated, ChainUpdated, ContainerWOUpdChain);
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
%%          erlang:display(["CmdList", CmdList, "ChainKeysAffected old container", ChainKeysAffectedNew]),
%%          erlang:display(["ChainKeyUpdated", ChainKeyUpdated]),
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
      case maps:get(ChainKey, LastEvents, undefined) of
        undefined ->
          recursively_insert_into_chain(RemKeys, CmdList, Container, LastPreds, LastEvents);
        LastID ->
          case sets:is_element(LastID, LastPreds) of
            true -> % can insert
              CmdListToInsert = paired_list_cmds_with_preds(CmdList, LastPreds),
              Chain1 = queue:from_list(lists:append(queue:to_list(Chain), CmdListToInsert)),
              {ChainKey, Chain1};
            false -> % cannot insert so recurse
              recursively_insert_into_chain(RemKeys, CmdList, Container, LastPreds, LastEvents)
          end
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