-module(bc_types).

-type broadcast() :: pid().
-type message() :: beb_message()
                 | rb_message()
                 | {deliver, message()}.
-type beb_message() :: nonempty_string().
-type rb_message() :: {atom(), non_neg_integer(), beb_message()}.

-export_type([broadcast/0, message/0]).