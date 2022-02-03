-module(scheduler).

-behaviour(gen_server).

-include("test_engine_types.hrl").

-export([start_link/1, start/1, init/1, handle_call/3, handle_cast/2, terminate/2]).
-export([choose_instruction/4]).

-record(state, {sched_name :: atom(), sched_state :: term()}).

%% BEHAVIOUR CALLBACKS
-callback get_kind_of_instruction(term()) -> kind_of_instruction().
-callback init(any()) -> {ok, term()}.
-callback update_state(term(), list()) -> term().
% produce_sut_instruction is (currently) the same for all schedulers
-callback produce_sched_instruction(SchedInstructions :: any(), CommandsInTransit :: list(), Timeouts :: list(), State :: term()) -> {#instruction{} | undefined, term()}.
-callback produce_timeout_instruction(Timeouts :: list(), State :: term()) -> {#instruction{} | undefined, term()}.
%% TODO: to add
%%-spec produce_node_connection_instruction(any(), any(), any(), #state{}) -> {#instruction{} | undefined, #state{}}.
-callback stop(term()) -> ok.

%%% API
-spec start_link(_) -> {'ok', pid()}.
start_link(Config) ->
  gen_server:start_link({local, ?MODULE}, ?MODULE, [Config], []).

start(Config) ->
  gen_server:start({local, ?MODULE}, ?MODULE, [Config], []).

-spec choose_instruction(Scheduler :: pid(), SUTModule :: atom(), [#abstract_instruction{}], history()) -> #instruction{}.
choose_instruction(Scheduler, SUTModule, SchedInstructions, History) ->
  gen_server:call(Scheduler, {choose_instruction, SUTModule, SchedInstructions, History}).

%% gen_server callback implementations

init([Config]) ->
  {SchedName, SchedState} = case maps:get(sched_name, Config, undefined) of
    undefined -> logger:warning("[~p] no scheduler provided", [?MODULE]);
    SchedName1 -> {ok, ModState1} = SchedName1:init([Config]),
               {SchedName1, ModState1}
  end,
  {ok, #state{sched_name = SchedName, sched_state = SchedState}}.

handle_call({choose_instruction, SUTModule, SchedInstructions, History}, _From,
    State = #state{sched_name = SchedName, sched_state = SchedState}) ->
  #prog_state{commands_in_transit = CommInTransit,
    timeouts = Timeouts,
    nodes = Nodes,
    crashed = Crashed} = helpers_scheduler:get_last_state_of_history(History),
  SchedState1 = SchedName:update_state(SchedState, CommInTransit),
  {Instruction, SchedState2} = get_next_instruction(SUTModule, SchedInstructions, CommInTransit, Timeouts, Nodes, Crashed, SchedName, SchedState1),
  {reply, Instruction, State#state{sched_state = SchedState2}};
handle_call(_Request, _From, State) ->
  logger:warning("[~p] unhandled call", ?MODULE),
  {reply, ok, State}.

handle_cast(_Request, State) ->
  {noreply, State}.

terminate(_Reason, #state{sched_name = SchedName, sched_state = SchedState}) ->
  SchedName:stop(SchedState),
  ok.

%% internal functions

-spec get_next_instruction( atom(), [#abstract_instruction{}], _, _, _, _, _, _) -> {#instruction{}, term()}.
get_next_instruction(SUTModule, SchedInstructions, CommInTransit, Timeouts, Nodes, Crashed, SchedName, SchedState) ->
%%  Crashed are the transient ones
  KindInstruction = SchedName:get_kind_of_instruction(SchedState),
  {NextInstruction, SchedState1} = case KindInstruction of
                      sut_instruction ->
                        {produce_sut_instruction(SUTModule), SchedState};
                      sched_instruction ->
                        SchedName:produce_sched_instruction(SchedInstructions, CommInTransit, Timeouts, SchedState);
                      timeout_instruction ->
                        SchedName:produce_timeout_instruction(Timeouts, SchedState);
                      node_connection_instruction ->
                        SchedName:produce_node_connection_instruction(Nodes, Crashed, SchedState)
                    end,
%%  in case an impossible kind was chose, we simply retry -> TODO: do better
  case NextInstruction of
    undefined -> get_next_instruction(SUTModule, SchedInstructions, CommInTransit, Timeouts, Nodes, Crashed, SchedName, SchedState1);
    SomeInstruction -> {SomeInstruction, SchedState1}
  end.

-spec produce_sut_instruction(atom()) -> #instruction{}.
produce_sut_instruction(SUTInstructionModule) ->
  % choose random abstract instruction
  Instructions = SUTInstructionModule:get_instructions(),
  Instr = lists:nth(rand:uniform(length(Instructions)), Instructions),
  SUTInstructionModule:generate_instruction(Instr).