%%%-------------------------------------------------------------------
%%% @author fms
%%% @copyright (C) 2021, <COMPANY>
%%% @doc
%%%
%%% @end
%%% Created : 06. Oct 2021 16:26
%%%-------------------------------------------------------------------
-module(scheduler_vanilla_fifo).
-author("fms").

-behaviour(gen_server).

-include("test_engine_types.hrl").

-record(state, {}).

-export([start_link/1, start/1, init/1, handle_call/3, handle_cast/2, terminate/2]).
-export([choose_instruction/5]).

%%% API
-spec start_link(_) -> {'ok', pid()}.
start_link(Config) ->
  gen_server:start_link({local, ?MODULE}, ?MODULE, [Config], []).

start(Config) ->
  gen_server:start({local, ?MODULE}, ?MODULE, [Config], []).

-spec choose_instruction(Scheduler :: pid(), MIL :: pid(), SUTModule :: atom(), [#abstract_instruction{}], history()) -> #instruction{}.
choose_instruction(Scheduler, MIL, SUTModule, SchedInstructions, History) ->
  %io:format("[~p] Choosing Instruction, History is: ~p~n", [?MODULE, History]),
  gen_server:call(Scheduler, {choose_instruction, MIL, SUTModule, SchedInstructions, History}).

%% gen_server callbacks

init([_Config]) ->
  {ok, #state{}}.

handle_call({choose_instruction, MIL, SUTModule, SchedInstructions, History}, _From, State = #state{}) ->
  #prog_state{commands_in_transit = CommInTransit} = getLastStateOfHistory(History),
  Result = get_next_instruction(MIL, SUTModule, SchedInstructions, CommInTransit),
  {reply, Result, State};
handle_call(_Request, _From, State = #state{}) ->
  erlang:throw("unhandled call"),
  {reply, ok, State}.

handle_cast(_Request, State = #state{}) ->
  {noreply, State}.

terminate(_Reason, _State = #state{}) ->
  ok.

%% internal functions

-spec getLastStateOfHistory(history()) -> #prog_state{}.
getLastStateOfHistory([]) ->
  #prog_state{};
getLastStateOfHistory([{_Cmd, State} | _Tail]) ->
  State.

-spec get_next_instruction(pid(), atom(), [#abstract_instruction{}], _) -> #instruction{}.
get_next_instruction(MIL, _SUTModule, _SchedInstructions, CommInTransit) when CommInTransit == [] ->
%%  TODO: change this in some way
  #instruction{module = message_interception_layer, function = no_op, args = [MIL]};
get_next_instruction(MIL, _SUTModule, _SchedInstructions, CommInTransit) when CommInTransit /= [] ->
%%  schedule next command
  [Command | _Tail] = CommInTransit,
  Args = get_args_from_command_for_mil(Command),
  ArgsWithMIL = [MIL | Args],
  #instruction{module = message_interception_layer, function = exec_msg_command, args = ArgsWithMIL}.

get_args_from_command_for_mil(Command) ->
  {Id, From, To, _Module, _Function, _Args} = Command,
  [Id, From, To].