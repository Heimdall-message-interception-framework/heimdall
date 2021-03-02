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
                  name = undefined :: string(),
                  class = undefined :: string(),
                  from = undefined :: string(),
                  to = undefined :: string(),
                  mesg = undefined :: any(),
                  old_mesg = undefined :: any(),
                  skipped = undefined :: list(number())
}).
