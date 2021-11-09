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
  last_predecessors = undefined :: sets:set(any()) | undefined,
  chain_map = maps:new() :: maps:map(integer(),
                                    maps:map(integer(), queue:queue({any(), sets:set(any())}))),
                                    % store cmd ids and predecessors
  command_ids_in_chains = sets:new() :: sets:set(any())
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
  % per recipient, construct a list of commands
  AddedCommandsByReceiver = lists:map(
    fun(Recipient) -> lists:filter(fun({_, _, To, _, _, _}) -> To == Recipient end, AddedCommands) end,
    RecipientsListUnique
  ),
  StrippedCommandsByReceiver = lists:map(
    fun(ListCmd) -> lists:map(fun({ID, _, _, _, _, _}) -> ID end, ListCmd) end,
    AddedCommandsByReceiver),
%%  2) for each command, insert it to chains
%%  2a) for the first in list, use the chain from which we took the last event (cannot have other events as just happened)
  {State1, RemainingCommandLists, ChainKeysAffected} =
    insert_first_into_last_chain_if_applicable(StrippedCommandsByReceiver, State),
%%  2b) for the remaining lists, check whether we can insert them in old ones one list by another
  {State2, ChainKeysAffected1} = lists:foldl(
    fun(CmdList, {StateAcc, ChainKeysAffectedAcc}) ->
      insert_into_chain(CmdList, ChainKeysAffectedAcc, StateAcc) end,
    {State1, ChainKeysAffected},
    RemainingCommandLists
  ),
%%  3) update (remaining) state
  State3 = State2#state{
    command_ids_in_chains = sets:union(IDsInChains, sets:from_list(AddedCommands))
  },
  {reply, ChainKeysAffected1, State3};
handle_call({get_first, ChainKey}, _From, State = #state{chain_map = ChainMap}) ->
  Chain = maps:get(ChainKey, ChainMap),
  case queue:out(Chain) of
    {{value, {ID, Preds}}, Chain1} ->
      Reply = {found, ID},
      ChainMap1 = maps:update(ChainKey, Chain1, ChainMap),
      LastChainKey1 = case queue:is_empty(Chain1) of
        % only store last chain key if queue is empty, ow. next events do not depend on last event in chain
        true -> ChainKey;
        false -> undefined
      end,
      State1 = State#state{chain_map = ChainMap1, last_chain_key = LastChainKey1, last_predecessors = Preds},
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
    State = #state{last_chain_container = LastContainer, last_chain_key = LastChainKey, chain_map = ChainMap}) ->
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
            Chain1 = queue:from_list(FirstCommandList),
            ChainContainer1 = maps:update(LastChainKey, Chain1, Container),
            ChainMap1 = maps:update(LastContainer, ChainContainer1, ChainMap),
            State1 = State#state{chain_map = ChainMap1},
            {State1, RemCommandsList,
              lists:duplicate(length(FirstCommandList), LastChainKey)};
          false -> % do not add them since they are concurrent
            {State, AddedCommandsByReceiver, []}
        end
    end.

insert_into_chain(CmdList, ChainKeysAffected, State) ->
  % iterate over chainmap and check whether there is either some chain to append or space
  SortedIndices = lists:sort(maps:keys(State#state.chain_map)),
  {State1, ChainKeysAffectedNew} =
    recursively_add_to_chains(SortedIndices, CmdList, State),
  ChainKeysAffected1 = lists:append(ChainKeysAffected, ChainKeysAffectedNew),
  {State1, ChainKeysAffected1}.

recursively_add_to_chains(SortedIndices, CmdList,
    State = #state{chain_map = ChainMap, next_chain_key = NextChainKey}) ->
  case SortedIndices of
    [] -> % add new chain_container
      NextContainerIndex = State#state.next_chain_container,
      NewContainer = maps:from_list([{NextChainKey, queue:from_list(CmdList)}]),
      ChainMap1 = maps:put(NextContainerIndex, NewContainer, ChainMap),
      State1 = State#state{
        next_chain_container = NextContainerIndex + 1,
        next_chain_key = NextChainKey + 1,
        chain_map = ChainMap1
      },
      ChainKeysAffectedNew = lists:duplicate(length(CmdList), NextChainKey),
      {State1, ChainKeysAffectedNew};
    [ContainerIndex | RemIndices] ->
      Container = maps:get(ContainerIndex, ChainMap),
      case insert_into_container(Container, ContainerIndex, CmdList, State) of
        full_container ->
          recursively_add_to_chains(RemIndices, CmdList, State);
        {ChainKeyUpdated, ChainUpdated, ContainerWOUpdChain, NextChainKeyUpd} ->
          ChainMap2 = case ContainerIndex == 1 of
                        true -> % no need swap, so insert back and return
                          maps:update(ChainKeyUpdated, ChainUpdated, ContainerWOUpdChain);
                        false -> % need to swap
                          LastContainerIndex = ContainerIndex - 1,
                          LastContainer = maps:get(LastContainerIndex, ChainMap),
                          % add UpdatedChain to last container
                          LastContainer1 = maps:update(ChainKeyUpdated, ChainUpdated, LastContainer),
                          % assign both containers new indices in chain_map
                          ChainMap3 = maps:update(LastContainerIndex, ContainerWOUpdChain, ChainMap),
                          maps:update(ContainerIndex, LastContainer1, ChainMap3)
                      end,
          State1 = State#state{chain_map = ChainMap2, next_chain_key = NextChainKeyUpd},
          ChainKeysAffectedNew = lists:duplicate(length(CmdList), ChainKeyUpdated),
          {State1, ChainKeysAffectedNew}
      end
  end.

insert_into_container(Container, MaxContainerSize, CmdList, State = #state{last_predecessors = LastPreds}) ->
%% returns {ChainKeyUpdated, ChainUpdated, ContainerWOUpdChain}
  % 1) check whether we can add and do if so
  SortedKeys = lists:sort(maps:keys(Container)),
  case recursively_insert_into_chain(SortedKeys, CmdList, Container, LastPreds) of
    checked_all_chains -> % did not find chain to insert so 2) new chain if possible
      case length(SortedKeys) < MaxContainerSize of
        true -> % can insert new chain
          NextChainKey = State#state.next_chain_key,
          PredsForCmds = lists:duplicate(length(CmdList), LastPreds),
          CmdListToInsert = lists:zip(CmdList, PredsForCmds),
          ChainUpdated = queue:from_list(CmdListToInsert),
          {NextChainKey, ChainUpdated, Container, NextChainKey+1}; % new chain
        false -> % cannot insert new chain
          full_container
      end;
    {ChainKeyUpdated, ChainUpdated} -> Container1 = maps:remove(ChainKeyUpdated, Container),
      {ChainKeyUpdated, ChainUpdated, Container1, State#state.next_chain_key} % chain existed
  end.


recursively_insert_into_chain(SortedKeys, CmdList, Container, LastPreds) ->
  case SortedKeys of
    [] -> % checked all chains so return
      checked_all_chains;
    [ChainKey | RemKeys] ->
      Chain = maps:get(ChainKey, Container),
      {LastID, _} = queue:head(Chain),
      case sets:is_element(LastID, LastPreds) of
        true -> % can insert
          PredsForLast = lists:reverse([LastPreds, lists:duplicate(length(CmdList)-1, undefined)]),
          CmdListToInsert = lists:zip(CmdList, PredsForLast),
          Chain1 = queue:from_list(lists:append(queue:to_list(Chain), CmdListToInsert)),
          {ChainKey, Chain1};
        false -> % cannot insert so recurse
          recursively_insert_into_chain(RemKeys, CmdList, Container, LastPreds)
      end
  end.

remove_dups([])    -> [];
remove_dups([H|T]) -> [H | [X || X <- remove_dups(T), X /= H]].