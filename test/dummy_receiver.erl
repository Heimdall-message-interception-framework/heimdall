%%%-------------------------------------------------------------------
%%% @author fms
%%% @copyright (C) 2021, <COMPANY>
%%% @doc
%%% @end
%%%-------------------------------------------------------------------
-module(dummy_receiver).

-behaviour(gen_server).

-export([start_link/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2,
  code_change/3]).

-define(SERVER, ?MODULE).

-record(state, {
  received_messages = [] :: [{From::pid(), To::pid(), Msg::any()}]
}).

%%%===================================================================
%%% Spawning and gen_server implementation
%%%===================================================================

start_link(Name) ->
  gen_server:start_link({local, Name}, ?MODULE, [], []).

init([]) ->
  {ok, #state{}}.

%% only payloads for readability
handle_call({get_received_payloads}, _From, State = #state{}) ->
  ReceivedPayloads = [P || {_, _, P} <- State#state.received_messages],
  {reply, ReceivedPayloads, State}.

handle_cast({message, From, To, Payload}, State = #state{}) ->
  UpdatedMessages = State#state.received_messages ++ [{From, To, Payload}],
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
