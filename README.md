sched_msg_interception_erlang
=====

Message interception and scheduling utilities for Erlang applications.

## Project Overview

This project maintains its code in several sub-projects:

- This repository host the **message interception layer (MIL)**. The MIL is used to intercept messages and schedule the delivery of messages in an Erlang program. This repo also includes a test-engine for orchestrating tests that leverage the MIL.
- RA-KV-Store: TODO
- RA: TODO
- Broadcast-Algos:

## Concepts

- MIL: TODO
- Test/Exploration-Engine: The exploration engine is used to run and orchestrate tests on a specific SUT. It issues API calls to the SUT and collects messages and program states after each step.
- SUT-Module: TODO
- Schedulers: TODO

## Usage

### Clone the Repo

```
$ git clone git-rts@gitlab.mpi-sws.org:fstutz/sched_msg_interception_erlang.git
```

### Build

    $ rebar3 compile


### Typecheck

    $ rebar3 dialyzer

### Testcases That Work
to be run on top level of the respective repo

    rebar3 ct --suite=test/basic_tests_SUITE.erl
    rebar3 ct --suite=test/gen_statem_timeouts/timeout_non_mi_tests_SUITE.erl
    rebar3 ct --suite=test/gen_statem_timeouts/timeout_mi_tests_SUITE.erl
    rebar3 ct --suite=test/broadcast_algorithms/broadcast_tests_SUITE.erl
    rebar3 ct --suite=test/raft/raft_observer_tests_SUITE.erl
    rebar3 ct --suite=test/broadcast_algorithms/bc_module_SUITE.erl

### Testcases That do NOT Work (yet again)

    $ rebar3 ct --suite=test/replay_tests_SUITE.erl
we keep them for potential future use but currently, this is not needed for our priority
