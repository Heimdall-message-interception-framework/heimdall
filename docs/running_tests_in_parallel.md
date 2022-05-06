# Running the Test Engine on multiple Nodes in parallel

## Introduction

This document outlines how to have the test engine running in parallel on multiple erlang VM nodes. All test engine nodes will run the tests while a master node hosts a shared MNESIA database. All nodes will store their test results in the shared database. The master node is the only node which shares the table as `disc_copies`and therefore persists it to disk.

## Start an MNESIA Master Node

Start an erlang shell in `sched_msg_interception_erlang`(this repo):

```shell
$ rebar3 shell --start-clean
```

On the erlang shell:

```shell
1> mnesia_functions:start_master("PATH/TO/MNESIA/DIR").
```

**Note that the path passed to MNESIA has to exist already, otherwise the function call will fail.**

## Running TestNodes

To run test nodes, we can start them - as usual - with the `rebar3 ct command`. In order to have them write to the shared database, we have to set `{persist, true}`in the test config and we have to start the node with a **unique name that is not yet taken**!

For example, in the `ra-kv-store` repo, we can do the following:

```shell
$ scheduler=test_fifo_scheduler PERSIST=true NUM_RUNS=3 NUM_PROCESSES=5 RUN_LENGTH=200 SIZE_D=5 rebar3 ct --sname worker_$scheduler\_$NUM_PROCESSES\_$SIZE_D --suite=test/ra-kv-store_module_SUITE.erl --case=$scheduler
```

`--sname`in the above command gives this test node a unique name based on the test config.
