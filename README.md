sched_msg_interception_erlang
=====

An OTP application

Build
-----

    $ rebar3 compile


Typecheck
-----

    $ rebar3 dialyzer

Testcases That Work
-----
to be run on top level of the respective repo

`sched_msg_interception_erlang`:

    $ rebar3 ct --suite=test/basic_tests_SUITE.erl
    $ rebar3 ct --suite=test/gen_statem_timeouts/timeout_non_mi_tests_SUITE.erl
    $ rebar3 ct --suite=test/broadcast_algorithms/broadcast_tests_SUITE.erl

`ra_kv_store`
 
Testcases for Future Features
-----
    $ rebar3 ct --suite=test/gen_statem_timeouts/timeout_mi_tests_SUITE.erl


Testcases That do NOT Work (yet again)
-----

    $ rebar3 ct --suite=test/replay_tests_SUITE.erl
we keep them for potential future use but currently, this is not needed for our priority
