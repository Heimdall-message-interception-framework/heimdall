%%%-------------------------------------------------------------------
%%% @author fms
%%% @copyright (C) 2021, <COMPANY>
%%% @doc
%%%
%%% @end
%%% Created : 01. Mar 2021 09:10
%%%-------------------------------------------------------------------
-module(msg_interception_helpers).
-author("fms").

-include("observer_events.hrl").

-define(ObserverManager, om).

%% API
-export([get_readable_time/0, remove_firstmatch/2, get_message_interception_layer/0, submit_sched_event/1]).

get_message_interception_layer() ->
  message_interception_layer.

submit_sched_event(Event) ->
  gen_event:sync_notify(?ObserverManager, {sched, Event}).


  - spec get_readable_time() -> [char()].
get_readable_time() ->
  {{Year, Month, Day}, {Hour, Min, Sec}} = calendar:now_to_local_time(erlang:timestamp()),
  io_lib:format("~.4.0w-~.2.0w-~.2.0w-~.2.0w:~.2.0w:~.2.0w", [Year, Month, Day, Hour, Min, Sec]).


- spec remove_firstmatch(fun((T) -> boolean()), [T]) -> no_such_element | {found, T, [T]}.
remove_firstmatch(CondFun, SomeList) ->
  remove_firstmatch(CondFun, [], SomeList).

remove_firstmatch(_CondFun, _ReversedFront, []) ->
  no_such_element;
remove_firstmatch(CondFun, ReversedFront, [X | Rest]) ->
  case CondFun(X) of
    true -> {found, X, lists:reverse(ReversedFront) ++ Rest};
    false -> remove_firstmatch(CondFun, [X | ReversedFront], Rest)
  end.
