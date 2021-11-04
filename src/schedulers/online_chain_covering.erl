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
-export([start_link/0, start/1, add_events/2, get_first_enabled/2]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2,
  code_change/3]).

-define(SERVER, ?MODULE).

-record(chain, {
  chain_key :: integer(),
  chain_content = queue:new() :: queue:queue({ID :: integer(), From :: any(), To :: any()}),
  dependencies = sets:new() :: sets:set(any()) % set of processes
}).

-record(chain_container, {
%%  index :: integer(),
  chains = [] :: lists:list(#chain{})
}).

-record(state, {
  last_chain_key = 1 :: integer(),
  chain_data = maps:from_list({1, #chain_container{}}) :: maps:map(integer(), #chain_container{}),
  command_ids_in_chains = sets:new() :: sets:set(any())
}).

%% TODO: add functions for init and handling calls

%%%===================================================================
%%% API
%%%===================================================================

%% @doc Spawns the server and registers the local name (unique)
-spec(start_link() ->
  {ok, Pid :: pid()} | ignore | {error, Reason :: term()}).
start_link() ->
  gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

start(Config) ->
  gen_server:start({local, ?MODULE}, ?MODULE, [Config], []).

add_events(OCC, CommInTransit) ->
%%  returns {ok, ListIDsAdded, ChainKeysAdded}
  gen_server:call(OCC, {add_events, CommInTransit}).

get_first_enabled(OCC, ChainKey) ->
%%  returns Maybe(Id, F, T) and which once become enabled if not none
  gen_server:call(OCC, {get_first_enabled, ChainKey}).

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
    State = #state{command_ids_in_chains = IDsInChains,
                   last_chain_key = LastChainKey,
                   chain_data = ChainContainerMap}) ->
%%  1) single out commands which are not in chain covering yet (maybe store ids in a set but keep consistent)
  AddedCommands = detect_added_commands_in_transit(IDsInChains, CommInTrans),
%%  2) for each command, update the dependencies of all chains
  MapFunForMapChainContainer = fun(NewCmd, MapChainContainerTemp) ->
    maps:map(
      fun(_Index, ChainContainer) -> update_dependencies_chain_container(ChainContainer, NewCmd) end,
      MapChainContainerTemp
    )
  end,
  ChainContainerMap1 = lists:foldl(MapFunForMapChainContainer, ChainContainerMap, AddedCommands),
%%  3) for each command, insert it to chain covering and swap the bags
  % find index to insert, i.e., a chaincontainer with a chain s.t. last element is related to next command
  {ChainContainerMap3, LastChainKey3} =
    lists:foldl(
      fun(NewCmd, {ChainContainerMap2, LastChainKey2}) ->
        insert_single_command(NewCmd, LastChainKey2, ChainContainerMap2) end,
      {ChainContainerMap1, LastChainKey},
      AddedCommands
    ),
%%  4) Update State
  AddedIDs = lists:map(fun({ID, _, _, _, _, _}) -> ID end, AddedCommands),
  State1 = State#state{
    command_ids_in_chains = sets:union(IDsInChains, AddedIDs),
    last_chain_key = LastChainKey3,
    chain_data = ChainContainerMap3
  },
%%  5) compute return
  ChainKeysAdded = lists:seq(LastChainKey, LastChainKey3 - 1), % update if name changes
  {ok, {AddedIDs, ChainKeysAdded}, State1};
handle_call({get_first_enabled, ChainKey}, _From,
    State = #state{chain_data = Chains}) ->
  ok; % TODO: proper return value
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

update_dependencies_chain_container(ChainContainer, NewCmd) ->
%%  total process order check does not need data, only (send, rcv) need
  {_, From, To, _, _, _} = NewCmd,
  FunctionToUpdateChainDependencies =
    fun(Chain = #chain{dependencies = Dependencies}) ->
%%      Invariant: From and To of last are always in Dependencies, then no need to check last element
        Dependencies1 = case sets:is_element(From, Dependencies) of
                          false -> Dependencies;
                          true -> sets:add_element(Dependencies, To)
                        end,
        Chain#chain{dependencies = Dependencies1}
    end,
  NewChains = lists:map(FunctionToUpdateChainDependencies, ChainContainer#chain_container.chains),
  ChainContainer#chain_container{chains = NewChains}.


command_can_be_added_chain_container(ChainContainer, {_From, To}) ->
  CommandCanBeAddedToChainFunc = fun(Chain = #chain{dependencies = Dependencies}, AccBoolean) ->
%%    a command can be added if From or To is in dependencies (we schedule receptions)
%%    if From was in there, we know that To is now in there as we updated
                                  AccBoolean or (sets:is_element(To, Dependencies))
                                  end,
  lists:foldl(CommandCanBeAddedToChainFunc, false, ChainContainer#chain_container.chains).

insert_single_command(NewCmd, LastChainKey, ChainContainerMap1) ->
  {_, From, To, _, _, _} = NewCmd,
  SequenceOfIndices = lists:seq(1, LastChainKey-1),
  FilterFunctionForIndices = fun(Index) ->
    ChainContainer = maps:get(Index, ChainContainerMap1),
    command_can_be_added_chain_container(ChainContainer, {From, To})
                             end,
  [IndexToAdd  | _ ] = lists:filter(FilterFunctionForIndices, SequenceOfIndices),
  % remove the first chain where it is possible from this chain container
  % or add a new chain and store the chainkey for this one -> CA (but small scope)
  ChainContainerAtIndex = maps:get(IndexToAdd, ChainContainerMap1),
  {ChainToAddTo, ChainContainerAtIndex1} =
    case get_first_chain_to_add_command(ChainContainerAtIndex, {From, To}) of
      {found, Chain, ChainContainerAtIndexTemp} -> {Chain, ChainContainerAtIndexTemp};
      {notfound} -> {#chain{chain_key = LastChainKey}, ChainContainerAtIndex}
    end,
  LastChainKey1 = LastChainKey + 1,
  % add the NewCmd to this chain
  ChainToAddTo1 = add_command_to_chain(ChainToAddTo, NewCmd),
  % if IndexToAdd > 1, swap the chain containers
  ChainContainerMap4 = case IndexToAdd > 1 of
                         false -> ChainContainerBelowIndex = maps:get(IndexToAdd-1, ChainContainerMap1),
                           BelowChains = ChainContainerBelowIndex#chain_container.chains,
                           BelowChains1 = lists:reverse([ChainToAddTo1 | lists:reverse(BelowChains)]),
                           ChainContainerBelowIndex1 = ChainContainerBelowIndex#chain_container{chains = BelowChains1},
                           ChainContainerMap2 = maps:update(IndexToAdd, ChainContainerBelowIndex1, ChainContainerMap1),
                           ChainContainerMap3 = maps:update(IndexToAdd, ChainContainerAtIndex1, ChainContainerMap2),
                           ChainContainerMap3;
                         true -> % we know that IndexToAdd is 1 then so single chain to which we added
                           AtIndexChains1 = [ChainToAddTo1],
                           ChainContainerAtIndex2 = ChainContainerAtIndex1#chain_container{chains = AtIndexChains1},
                           maps:update(IndexToAdd, ChainContainerAtIndex2, ChainContainerMap1)
                       end,
  {ChainContainerMap4, LastChainKey1}.

get_first_chain_to_add_command(#chain_container{chains = Chains}, {From, To}) ->
%%  we know that it exists (or the container is not full yet)
  get_first_chain_to_add_command([], Chains, {From, To}).

get_first_chain_to_add_command(PrefixChains, SuffixChains, {From, To}) ->
%%  note that PrefixChains is reversed and we reverse it when returning
  case SuffixChains of
    [Chain | SuffixChains1] ->
      case command_can_be_added_chain(Chain, {From, To}) of
        true -> {found, Chain, lists:append(lists:reverse(PrefixChains), SuffixChains1)};
        false -> PrefixChains1 = [Chain | PrefixChains],
                 get_first_chain_to_add_command(PrefixChains1, SuffixChains1, {From, To})
      end;
    [] -> {notfound}
  end.

add_command_to_chain(Chain = #chain{chain_content = ChainContent, dependencies = Dependencies}, NewCmd) ->
  {ID, From, To, _, _, _} = NewCmd,
  ChainContent1 = queue:in({ID, From, To}, ChainContent),
  Dependencies1 = sets:from_list([To]),
  Chain#chain{chain_content = ChainContent1, dependencies = Dependencies1}.


command_can_be_added_chain(#chain{dependencies = Dependencies}, {From, To}) ->
  (sets:is_element(From, Dependencies)) or (sets:is_element(To, Dependencies)).