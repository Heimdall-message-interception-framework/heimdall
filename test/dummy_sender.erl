%%%-------------------------------------------------------------------
%%% @author fms
%%% @copyright (C) 2021, <COMPANY>
%%% @doc
%%% @end
%%%-------------------------------------------------------------------
-module(dummy_sender).

-behaviour(gen_server).

-export([start/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2,
  code_change/3]).

-record(state, {
}).

%%%===================================================================
%%% Spawning and gen_server implementation
%%%===================================================================

start(Name) ->
  gen_server:start_link({local, Name}, ?MODULE, [], []).

init([]) ->
  {ok, #state{}}.

handle_call(_Request, _From, State = #state{}) ->
  {reply, ok, State}.

handle_cast({send_N_messages_with_interval, To, {N, Interval}}, State = #state{}) ->
  send_N_messages_with_interval(State, N, To, Interval),
  {noreply, State};
%%
handle_cast({casted, To, {send_N_messages_with_interval, N, Interval}}, State = #state{}) ->
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
    N > 0 ->
      message_interception_layer:msg_command(self(), To, gen_server, cast, [To, {message, N}]),
      timer:sleep(Interval),
      send_N_messages_with_interval(State, N-1, To, Interval);
    N == 0 ->
      message_interception_layer:msg_command(self(), To, gen_server, cast, [To, {message, N}])
  end.
