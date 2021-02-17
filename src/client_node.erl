%%%-------------------------------------------------------------------
%%% @author fms
%%% @copyright (C) 2021, <COMPANY>
%%% @doc
%%% @end
%%%-------------------------------------------------------------------
-module(client_node).

-behaviour(gen_server).

-export([start/2]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2,
  code_change/3]).

-define(SERVER, ?MODULE).

-record(state, {
  message_interception_layer_id :: pid()
}).

%%%===================================================================
%%% Spawning and gen_server implementation
%%%===================================================================

start(Name, MIL) ->
  gen_server:start_link({local, Name}, ?MODULE, [MIL], []).

init([MIL]) ->
  {ok, #state{message_interception_layer_id = MIL}}.

handle_call(_Request, _From, State = #state{}) ->
  {reply, ok, State}.

handle_cast({client_req, ClientName, Coordinator, ClientCmd}, State = #state{}) ->
  gen_server:cast(State#state.message_interception_layer_id, {fwd_client_req, ClientName, Coordinator, ClientCmd}),
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
