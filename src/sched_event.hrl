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
                  what :: string(), %% we could be more precise here
                  id = undefined :: number(),
                  node = undefined :: string(),
                  from = undefined :: string(),
                  to = undefined :: string(),
                  mesg = undefined :: string(),
                  old_mesg = undefined :: string(),
                  skipped = undefined :: list(string())
}).
