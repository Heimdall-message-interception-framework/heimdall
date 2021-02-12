%%%-------------------------------------------------------------------
%%% @author fms
%%% @copyright (C) 2021, <COMPANY>
%%% @doc
%%% @end
%%%-------------------------------------------------------------------
-module(test_scheduler).
-include_lib("eunit/include/eunit.hrl").

-behaviour(gen_server).

-export([start_link/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2,
  code_change/3]).

-define(SERVER, ?MODULE).

-record(test_scheduler_state, {}).

%%%===================================================================
%%% Spawning and gen_server implementation
%%%===================================================================

start_link() ->
  gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

init([]) ->
  {ok, #test_scheduler_state{}}.

handle_call(_Request, _From, State = #test_scheduler_state{}) ->
  {reply, ok, State}.

handle_cast(_Request, State = #test_scheduler_state{}) ->
  {noreply, State}.

handle_info(_Info, State = #test_scheduler_state{}) ->
  {noreply, State}.

terminate(_Reason, _State = #test_scheduler_state{}) ->
  ok.

code_change(_OldVsn, State = #test_scheduler_state{}, _Extra) ->
  {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================


scheduler_test() ->
  {ok, MIL, MessageCollector} = message_interception_layer:start([]),
  gen_server:cast(MessageCollector, {send, self(), self(), "some message"}),
  erlang:display("send some message"),
  gen_server:cast(MIL, {start}),
  receive
    _ ->
      erlang:display("received some message")
  end,
  erlang:display("end").
