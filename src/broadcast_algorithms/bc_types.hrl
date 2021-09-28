-type broadcast() :: pid().
-type bc_message() :: beb_message()
                 | rb_message().
-type beb_message() :: nonempty_string().
-type rb_message() :: {atom(), non_neg_integer(), beb_message()}.