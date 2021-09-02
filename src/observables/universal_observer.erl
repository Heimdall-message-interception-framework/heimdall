-module(universal_observer).
% a universal observer which tracks changes to every instrumented variable and message. Every change is logged to stdout.
-behaviour(gen_event).

-export([init/1, handle_call/2, handle_event/2]).

-record(state, {local_delivered :: sets:set()}).

init(_) ->
    {ok, #state{local_delivered = sets:new()}}.
handle_event({update, Proc, VarName, Old, New}, State) ->
    io:format("[univ_observer] ~s:~s changed from ~p to ~p~n", [Proc, VarName, Old,New]),
    {ok, State};
handle_event({msg, MsgCmd, Id, From, To, Mod, Func}, State) ->
    % TODO: do sth. useful here
    {ok, State};
handle_event(Event, State) ->
    io:format("[univ_observer] received unhandled event: ~p~n", [Event]),
    {ok, State}.

handle_call(Msg, State) ->
    io:format("[univ_observer] received unhandled call: ~p~n", [Msg]),
    {ok, ok, State}.