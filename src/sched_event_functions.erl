%%%-------------------------------------------------------------------
%%% @author fms
%%% @copyright (C) 2021, <COMPANY>
%%% @doc
%%%
%%% @end
%%% Created : 01. Mar 2021 12:03
%%%-------------------------------------------------------------------
-module(sched_event_functions).
-include_lib("sched_event.hrl").
-author("fms").

%% API
-export([event_for_matching/1]).


event_for_matching(SchedEvent) ->
%%  so far, it is as simple as this is
  (SchedEvent#sched_event.what == received) orelse (SchedEvent#sched_event.what == rcv_crsh).