-module(best_effort_broadcast_paper).
%% best effort broadcast inspired by [Zeller2020](https://doi.org/10.1145/3406085.3409009)

-include("include/observer_events.hrl").
-include("bc_types.hrl").
-behavior(gen_server).

-export([start_link/3, broadcast/2]).

% gen_server callbacks
-export([handle_call/3, handle_cast/2, handle_info/2, init/1, terminate/2]).

-record(state, {
	link_layer	:: pid(), % link layer
	deliver_to	:: pid(), % receiver
	self		:: nonempty_string() % name of local process
}).

-spec start_link(pid(), nonempty_string(), pid()) -> {'error', _} | {'ok', broadcast()}.
start_link(LinkLayer, ProcessName, RespondTo) ->
	gen_server:start_link(?MODULE, [LinkLayer, ProcessName, RespondTo], []).

% broadcasts a message to all other nodes that we are connected to
-spec broadcast(broadcast(), bc_message()) -> any().
broadcast(B, Msg) ->
	% erlang:display("Broadcasting: ~p~n", [Msg]),
	gen_server:call(B, {broadcast, Msg}).

init([LL, Name, R]) ->
	% register at link layer in order to receive broadcasts from others
	link_layer:register(LL, Name, self()),
	{ok, #state{
		link_layer = LL,
		deliver_to = R,
		self = unicode:characters_to_list([Name| "_be"])
	}}.

-spec handle_call({'broadcast', bc_message()}, _, #state{}) -> {'reply', 'ok', #state{}}.
handle_call({broadcast, Msg}, _From, State) ->
	%%% OBS
    gen_event:sync_notify(om, {process, #obs_process_event{
		process = self(),
		event_type = bc_broadcast_event,
		event_content = #bc_broadcast_event{
			message = Msg
		}
	}}),
	%%% SBO
	% deliver locally
	State#state.deliver_to ! {deliver, Msg},
	%%% OBS
	Event = {process, #obs_process_event{
		process = self(),
		event_type = bc_delivered_event,
		event_content = #bc_delivered_event{
			message = Msg
		}
	}},
    gen_event:sync_notify(om, Event),
	%%% SBO
	% broadcast to everyone
	LL = State#state.link_layer,
	{ok, AllNodes} = link_layer:all_nodes(LL),
	[link_layer:send(LL, {deliver, Msg}, self(), Node) || Node <- AllNodes, Node =/= self()],
	%%% OBS
    gen_event:sync_notify(om, {process, #obs_process_event{
		process = self(),
		event_type = bc_broadcast_event,
		event_content = #bc_broadcast_event{
			message = Msg
		}
	}}),
	%%% SBO
	{reply, ok, State}.

-spec handle_info({deliver, bc_message()}, _) -> {'noreply', _}.
handle_info({deliver, Msg}, State) ->
	State#state.deliver_to ! {deliver, Msg},
	%%% OBS
    gen_event:sync_notify(om, {process, #obs_process_event{
		process = self(),
		event_type = bc_delivered_event,
		event_content = #bc_delivered_event{
			message = Msg
		}
	}}),
	%%% SBO
	{noreply, State};
handle_info(Msg, State) ->
    io:format("[best_effort_bc_paper] received unknown message: ~p~n", [Msg]),
	{noreply, State}.

handle_cast(Msg, State) ->
    io:format("[best_effort_bc_paper] received unhandled cast: ~p~n", [Msg]),
	{noreply, State}.

terminate(_Reason, _State) ->
	ok.