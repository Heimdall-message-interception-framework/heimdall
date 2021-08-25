%%%-------------------------------------------------------------------
%%% @author fms
%%% @copyright (C) 2021, <COMPANY>
%%% @doc
%%%
%%% @end
%%% Created : 26. Feb 2021 13:25
%%%-------------------------------------------------------------------
-author("fms").

-type sched_event_type() :: reg_node | reg_clnt
                          | cmd_rcv | cmd_rcv_crsh | exec_msg_cmd
                          | enable_to | enable_to_crsh | disable_to
                          | duplicat | snd_altr | drop_msg
                          | trns_crs | rejoin | perm_crs.

-export_type([sched_event_type/0]).

-record(sched_event, {
                  what :: sched_event_type(),
                  id = undefined :: number(),
                  name = undefined :: atom() | undefined,
                  class = undefined :: atom() | undefined,
                  from = undefined :: atom() | undefined,
                  to = undefined :: atom() | undefined,
%%                  mesg = undefined :: any(),
%%                  old_mesg = undefined :: any(),
                  skipped = undefined :: list(number()) | undefined,
                  mod = undefined :: atom() | undefined,
                  func = undefined :: atom() | undefined,
                  args = undefined :: list(any()) | undefined
}).
