%%%-------------------------------------------------------------------
%% @doc sched_msg_interception_erlang public API
%% @end
%%%-------------------------------------------------------------------

-module(sched_msg_interception_erlang_app).

-behaviour(application).

-export([start/2, stop/1]).

start(_StartType, _StartArgs) ->
    sched_msg_interception_erlang_sup:start_link().

stop(_State) ->
    ok.

%% internal functions
