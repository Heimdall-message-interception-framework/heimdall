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
  last_chain_key = undefined :: integer() | undefined,
  chain_map = maps:new() :: maps:map(integer(), queue:queue()),
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

start(Config) ->
  gen_server:start({local, ?MODULE}, ?MODULE, [Config], []).

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
    State = #state{command_ids_in_chains = IDsInChains,
                   next_chain_key = NextChainKey,
                   last_chain_key = LastChainKey,
                   chain_map = ChainMap}) ->
%%  1a) single out commands which are not in chain covering yet (maybe store ids in a set but keep consistent)
  AddedCommands = detect_added_commands_in_transit(IDsInChains, CommInTrans),
%%  1b) partition them by receiver since they go in the same chain
  % get all recipients
  RecipientsListNonUnique = lists:reverse(
    lists:foldl(fun({_, _, To, _, _, _}, AccListRev) -> [To | AccListRev] end, [], AddedCommands)
  ),
  RecipientsListUnique = lists:reverse(lists:foldl(
    fun({_, _, To, _, _, _}, AccList) ->
      case lists:member(To, AccList) of
         true -> AccList;
         false -> [To, AccList]
      end
    end,
    [],
    RecipientsListNonUnique)),
  % per recipient, construct a list of commands
  AddedCommandsByReceiver = lists:map(
    fun(Recipient) -> lists:filter(fun({_, _, To, _, _, _}) -> To == Recipient end, AddedCommands) end,
    RecipientsListUnique
  ),
%%  2) for each command, insert it to chains
%%  2a) for the first in list, use the chain from which we took the last event (cannot have other events as just happened)
  {ChainMap2, RemainingCommandLists, ChainKeysAffected} = case LastChainKey of
                                     undefined -> {ChainMap, AddedCommands, []};
                                     _ActualChainKey ->
                                       [FirstCommandList | RemCommandsList] = AddedCommandsByReceiver,
                                       ChainMap1 = maps:update(LastChainKey, FirstCommandList, ChainMap),
                                       {ChainMap1, RemCommandsList,
                                         lists:duplicate(length(FirstCommandList), LastChainKey)}
  end,
%%  2b) for the remaining, create new ones (do not re-use as we'd re-use priorities as well)
  ListIndicesForRemainingCmds = lists:seq(NextChainKey, NextChainKey + length(RemainingCommandLists)),
  ListIndicesAndCmdLists = lists:zip(ListIndicesForRemainingCmds, RemainingCommandLists),
  NextChainKey1 = NextChainKey + length(RemainingCommandLists) + 1,
  ChainMap3 = lists:foldl(
    fun({ChainKeyCurrent, CmdList}, {ChainMapTemp, ChainKeysAffectedTemp}) ->
      ChainMapTemp1 = maps:update(ChainKeyCurrent, CmdList, ChainMapTemp),
      ChainKeysAffectedTemp1 = lists:append(ChainKeysAffectedTemp,
                                            lists:duplicate(length(CmdList), ChainKeyCurrent)),
      {ChainMapTemp1, ChainKeysAffectedTemp1}
    end,
    {ChainMap2, ChainKeysAffected},
    ListIndicesAndCmdLists
  ),
%%  3) update state
  AddedIDs = lists:map(fun({ID, _, _, _, _, _}) -> ID end, AddedCommands),
  State1 = State#state{
    command_ids_in_chains = sets:union(IDsInChains, sets:from_list(AddedIDs)),
    next_chain_key = NextChainKey1,
    chain_map = ChainMap3
  },
%%  4) compute return
  ChainKeysAffected1 = lists:zip(ChainKeysAffected, lists:seq(NextChainKey, NextChainKey1 - 1)),
  {reply, ChainKeysAffected1, State1};
handle_call({get_first, ChainKey}, _From,
    State = #state{chain_map = ChainMap}) ->
  Chain = maps:get(ChainKey, ChainMap),
  case queue:out(Chain) of
    {{value, {ID, From, To}}, Chain1} ->
      Reply = {found, {ID, From, To}},
      ChainMap1 = maps:update(ChainKey, Chain1, ChainMap),
      LastChainKey1 = case queue:is_empty(Chain1) of
        % only store last chain key if queue is empty, ow. next events do not depend on last event in chain
        true -> ChainKey;
        false -> undefined
      end,
      State1 = State#state{chain_map = ChainMap1, last_chain_key = LastChainKey1},
      {reply, Reply, State1};
    {empty, _} -> % once empty (after one round nothing added), it shall not be refilled
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
  HelperPredicate = fun({ID, _, _, _, _, _}) -> (not sets:is_element(ID, CommInChains)) end,
  lists:filter(HelperPredicate, CommInTrans).