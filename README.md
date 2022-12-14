Heimdall
=====

Message interception and scheduling utilities for Erlang applications.

## Project Overview

This project maintains its code in several sub-projects:

This repository hosts the **message interception layer (MIL)**. The MIL is used to intercept messages and schedule the delivery of messages in an Erlang program. This repo also includes an **exploration engine** for orchestrating tests that leverage the MIL.

The first case study is a key-value store based on Raft.
We instrumented their code which can be found in the respective repositories.

## Concepts

This section introduces the different modules and concepts which are needed to test an application. In this readme, we try to give a more high-level description. For more in-depth explanations of the source code and the API of the different modules, [edoc](https://www.erlang.org/doc/apps/edoc/chapter.html) can be generated by running `rebar3 edoc`.

- **Message Interception Layer (MIL):** The MIL can be used to intercept communication (messages) between Erlang processes. This allows scheduling messages in a user defined way in order to simulate various reordering scenarios that can happen in real systems due to unreliable message delivery. The MIL includes "drop-in" implementations for Erlang's `gen_server` modules, therefore applications which are built using these abstractions can be instrumented to use the MIL with minimal effort. Applications which use Erlang's messaging primitives directly (e.g. the `!` operator) need these calls to be instrumented manually.
- **Exploration Engine:** The exploration engine is used to run and orchestrate tests on a specific SUT. It issues API calls to the SUT and collects messages and program states after each step. This allows to systematically explore the different possible linearizations in a message-passing program.
- **SUT-Module:** This module encapsulates everything that the test engine needs to know about a specific system/application under test.
- Schedulers: Our Framework allows to implement various schedulers like PCT or FIFO scheduling but also more complex schedulers that incorporate information about the state of the execution into the decision making.

## Usage

After cloning the repository, follow the following steps.

### Build

    $ rebar3 compile

### Generate [Edoc](https://www.erlang.org/doc/apps/edoc/chapter.html)

    $ rebar3 edoc

### Typecheck

    $ rebar3 dialyzer

### Testcases 
(to be run on top level of the repository)

    rebar3 ct --suite=test/basic_tests_SUITE.erl
    rebar3 ct --suite=test/gen_statem_timeouts/timeout_non_mi_tests_SUITE.erl
    rebar3 ct --suite=test/gen_statem_timeouts/timeout_mi_tests_SUITE.erl
    rebar3 ct --suite=test/broadcast_algorithms/broadcast_tests_SUITE.erl
    rebar3 ct --suite=test/raft/raft_observer_tests_SUITE.erl
    rebar3 ct --suite=test/broadcast_algorithms/bc_module_SUITE.erl
