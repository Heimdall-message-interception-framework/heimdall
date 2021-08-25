%%%-------------------------------------------------------------------
%%% @author fms
%%% @copyright (C) 2021, <COMPANY>
%%% @doc
%%%
%%% @end
%%% Created : 01. Mar 2021 09:12
%%%-------------------------------------------------------------------
-module(logging_configs).
-author("fms").

%% API
-export([get_config_for_readable/1, get_config_for_machine/1]).
%%  TODO: add filter if "what" is undefined

-spec get_config_for_readable(atom()) -> {string(), #{config := term(), formatter := term(), level := atom()}}.
get_config_for_readable(TestCaseName) ->
  erlang:display(c:pwd()),
  FileName = "./../../../../logs/schedules/" ++ msg_interception_helpers:get_readable_time() ++ "_" ++
              erl_types:atom_to_string(TestCaseName) ++ "__readable.sched",
  LogConfigReadable = #{config => #{file => FileName},
    formatter => {logger_formatter, #{
      template =>  [what, "\t",
        {id, ["ID: ", id, "\t"], []},
        {name, ["Name: ", name, "\t"], []},
        {class, ["Class: ", class, "\t"], []},
        {from, ["From: ", from, "\t"], []},
        {to, [" To: ", to, "\t"], []},
%%        {mesg, [" Msg: ", mesg, "\t"], []},
%%        {old_mesg, [" Old Msg: ", old_mesg, "\t"], []},
        {skipped, [" Skipped: ", skipped, "\t"], []},
        {mod, ["Module: ", mod, "\t"], []},
        {func, [" Func: ", func, "\t"], []},
        {args, [" Args: ", args, "\t"], []},
        "\n"]
    }},
    level => debug},
  {FileName, LogConfigReadable}.

-spec get_config_for_machine(atom()) -> {string(), #{config := term(), formatter := term(), level := atom()}}.
get_config_for_machine(TestCaseName) ->
  FileName = "./../../../../logs/schedules/" ++ msg_interception_helpers:get_readable_time() ++ "_" ++
              erl_types:atom_to_string(TestCaseName) ++  "__machine.sched",
  LogConfigMachine = #{config => #{file => FileName},
%%    TODO: change formatter in a way that it check whether it is a sched_event
    formatter => {logger_formatter, #{
      template =>  ["{sched_event, ",
        {what, [what], ["undefined"]}, ", ",
        {id, [id], ["undefined"]}, ", ",
        {name, [name], ["undefined"]}, ", ",
        {class, [class], ["undefined"]}, ", ",
        {from, [from], ["undefined"]}, ", ",
        {to, [to], ["undefined"]}, ", ",
%%        {mesg, [mesg], ["undefined"]}, ", ",
%%        {old_mesg, [old_mesg], ["undefined"]}, ", ",
        {skipped, [skipped], ["undefined"]}, ", ",
        {mod, [mod], ["undefined"]}, ", ",
        {func, [func], ["undefined"]}, ", ",
        {args, [args], ["undefined"]},
        "}.\n"]
    }},
    level => debug},
  {FileName, LogConfigMachine}.