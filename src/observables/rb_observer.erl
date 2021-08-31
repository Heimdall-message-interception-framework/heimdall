-module(rb_observer).
% a simple observer which tracks changes to the local_delivered variable of reliable broadcasts. Every change is logged to stdout.
-behaviour(gen_event).

-export([init/1, handle_call/2, handle_event/2]).

-record(state, {local_delivered :: sets:set()}).

init(_) ->
    {ok, #state{local_delivered = sets:new()}}.
handle_event({update, "local_delivered", Old, New}, State) ->
    io:format("[rb_observer] 'local_delivered' changed from ~p to ~p~n", [Old,New]),
    {ok, State#state{local_delivered=New}};
handle_event(Event, State) ->
    io:format("[rb_observer] received unhandled event: ~p~n", [Event]),
    {ok, State}.

handle_call(Msg, State) ->
    io:format("[rb_observer] received unhandled call: ~p~n", [Msg]),
    {ok, ok, State}.