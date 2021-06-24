%%%-------------------------------------------------------------------
%%% @author fms
%%% @copyright (C) 2021, <COMPANY>
%%% @doc
%%%
%%% @end
%%% Created : 26. Feb 2021 13:25
%%%-------------------------------------------------------------------
-author("fms").

-record(sched_event, {
                  what :: atom(), %% we could be more precise here
                  id = undefined :: number(),
                  name = undefined :: atom() | undefined,
                  class = undefined :: atom() | undefined,
                  from = undefined :: atom() | undefined,
                  to = undefined :: atom() | undefined,
                  mesg = undefined :: any(),
                  old_mesg = undefined :: any(),
                  skipped = undefined :: list(number()) | undefined,
                  mod = undefined :: atom() | undefined,
                  func = undefined :: atom() | undefined,
                  args = undefined :: list(any()) | undefined
}).
