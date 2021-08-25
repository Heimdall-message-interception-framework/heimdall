%%%-------------------------------------------------------------------
%%% @author fms
%%% @copyright (C) 2021, <COMPANY>
%%% @doc
%%% @end
%%%-------------------------------------------------------------------
-module(dummy_receiver).

-behaviour(gen_server).

-export([start/2]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2,
  code_change/3]).

-define(SERVER, ?MODULE).

-record(state, {
  received_messages = [] :: [{From::pid(), To::pid(), Msg::any()}]
}).

%%%===================================================================
%%% Spawning and gen_server implementation
%%%===================================================================

start(Name, MIL) ->
  gen_server:start_link({local, Name}, ?MODULE, [MIL], []).

init([_MIL]) ->
  {ok, #state{}}.

handle_call({get_received_payloads}, _From, State = #state{}) ->
  {reply, State#state.received_messages, State}.

handle_cast({message, Payload}, State = #state{}) ->
  UpdatedMessages = State#state.received_messages ++ [Payload],
  {noreply, State#state{received_messages = UpdatedMessages}}.

handle_info(_Info, State = #state{}) ->
  {noreply, State}.

terminate(_Reason, _State = #state{}) ->
  ok.

code_change(_OldVsn, State = #state{}, _Extra) ->
  {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================
