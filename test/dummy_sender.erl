%%%-------------------------------------------------------------------
%%% @author fms
%%% @copyright (C) 2021, <COMPANY>
%%% @doc
%%% @end
%%%-------------------------------------------------------------------
-module(dummy_sender).

-behaviour(gen_server).

-export([start/2]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2,
  code_change/3]).

-define(SERVER, ?MODULE).

-record(state, {
  message_collector_id :: pid()
}).

%%%===================================================================
%%% Spawning and gen_server implementation
%%%===================================================================

start(Name, MessageCollector) ->
  gen_server:start_link({local, Name}, ?MODULE, [MessageCollector], []).

init([MessageCollector]) ->
  {ok, #state{message_collector_id = MessageCollector}}.

handle_call(_Request, _From, State = #state{}) ->
  {reply, ok, State}.

handle_cast({send_N_messages_with_interval, {N, To, Interval}}, State = #state{}) ->
  send_N_messages_with_interval(State, N, To, Interval),
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

send_N_messages_with_interval(State, N, To, Interval) ->
  if
    N > 0 -> gen_server:cast(State#state.message_collector_id, {send, self(), To, N}),
      timer:sleep(Interval),
      send_N_messages_with_interval(State, N-1, To, Interval);
    N == 0 -> gen_server:cast(State#state.message_collector_id, {send, self(), To, N})
  end.
