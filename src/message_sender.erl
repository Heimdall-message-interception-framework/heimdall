%%%-------------------------------------------------------------------
%%% @author fms
%%% @copyright (C) 2021, <COMPANY>
%%% @doc
%%% @end
%%%-------------------------------------------------------------------
-module(message_sender).

-behaviour(gen_server).

-export([start/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2,
  code_change/3]).

-define(SERVER, ?MODULE).

-record(state, {}).

%%%===================================================================
%%% Spawning and gen_server implementation
%%%===================================================================

start() ->
  gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

init([]) ->
  {ok, #state{}}.

handle_call(_Request, _From, State = #state{}) ->
  {reply, ok, State}.

handle_cast({send, From, To, Payload}, State = #state{}) ->
%%  TODO: change once wrapper API is defined
  To ! {remote, From, Payload},
  erlang:display("message has been forwarded."),
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
