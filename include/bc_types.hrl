-type broadcast() :: pid().
-type bc_message() :: beb_message()
                 | rb_message()
                 | cb_message().
-type beb_message() :: nonempty_string().
-type rb_message() :: {atom() | nonempty_string(), non_neg_integer(), beb_message()}.
-type cb_message() :: {Sender :: nonempty_string(), vectorclock:vectorclock(), beb_message()}.
