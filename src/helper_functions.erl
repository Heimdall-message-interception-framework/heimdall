%%%-------------------------------------------------------------------
%%% @author fms
%%% @copyright (C) 2021, <COMPANY>
%%% @doc
%%%
%%% @end
%%% Created : 01. Mar 2021 09:10
%%%-------------------------------------------------------------------
-module(helper_functions).
-author("fms").

%% API
-export([get_readable_time/0, assert_equal/2]).

get_readable_time() ->
  {{Year, Month, Day}, {Hour, Min, Sec}} = calendar:now_to_datetime(erlang:timestamp()),
  io_lib:format("~.4.0w-~.2.0w-~.2.0wT~.2.0w:~.2.0w:~.2.0w", [Year, Month, Day, Hour, Min, Sec]).

assert_equal(First, Second) ->
  case First == Second of
    true -> ok;
    false -> ct:fail("not the same")
  end.

