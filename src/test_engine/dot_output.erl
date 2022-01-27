%%%-------------------------------------------------------------------
%%% @author fms
%%% @copyright (C) 2022, <COMPANY>
%%% @doc
%%%
%%% @end
%%% Created : 27. Jan 2022 10:47
%%%-------------------------------------------------------------------
-module(dot_output).
-author("fms").

-include("raft_abstraction_types.hrl").

-define(PARTSINFOSEP, " | | \n").
-define(NODENAMEPREFIX, "node_").

%% API
-export([output_dot/2]).


%%====================================================================
%% API functions
%%====================================================================

-spec output_dot(nonempty_string(), #abs_log_tree{}) -> 'ok'.
output_dot(Filename, AbsLogTree) ->
  % offload to separate process
  spawn(fun() ->
    Dot = abslogtree_to_dot(AbsLogTree),
    write_file(Dot, Filename ++ ".dot") end
  ),
  ok.

%%====================================================================
%% Internal functions
%%====================================================================

-spec write_file(binary() | maybe_improper_list(binary() | maybe_improper_list(any(), binary() | []) | char(), binary() | []), atom() | binary() | [atom() | [any()] | char()]) -> 'ok' | {'error', atom()}.
write_file(String, Filename) ->
  logger:info("[~p] Writing file ~p~n", [?MODULE, Filename]),
  file:write_file(Filename, unicode:characters_to_binary(String)).

-spec abslogtree_to_dot(#abs_log_tree{}) -> nonempty_string().
abslogtree_to_dot(AbsLogTree) ->
  dot_prefix() ++
  abslogtree_to_dot_rec(AbsLogTree, "1") ++
  dot_postfix() ++ "\n" ++
  comment_abslog_tree(AbsLogTree).

-spec abslogtree_to_dot_rec(#abs_log_tree{}, nonempty_string()) -> nonempty_string().
abslogtree_to_dot_rec(#abs_log_tree{part_info = PartsInfo, children = Children}, NameSuffix) ->
  PartsInfoDotList = lists:map(fun(PartInfo) -> partinfo_to_dot(PartInfo) end, PartsInfo),
  PartsInfoDotString = lists:flatten(lists:join(?PARTSINFOSEP, PartsInfoDotList)),
  ChildrenNewLine = case length(PartsInfo) of
                      0 -> "";
                      _ -> "\n"
                    end,
  NodeDotString = ?NODENAMEPREFIX ++ NameSuffix ++ "   [ shape=record label=\" | " ++ ChildrenNewLine ++
    PartsInfoDotString ++ " | " ++ ChildrenNewLine ++ "\"]",
  ParentChildrenConnectionsDotString = get_arrows_parent_to_children(?NODENAMEPREFIX ++ NameSuffix, length(Children)),
  ChildrenZippedSequence = lists:zip(lists:seq(1, length(Children)), Children),
  ChildrenDotString = lists:foldl(
    fun({Number, Child}, Acc) ->
      NameSuffix1 = NameSuffix ++ erlang_to_string(Number),
      ChildDotString = abslogtree_to_dot_rec(Child, NameSuffix1),
      Acc ++ "\n" ++ ChildDotString
    end,
    "",
    ChildrenZippedSequence),
%%  arrows from parent to child
  NodeDotString ++ "\n" ++ ParentChildrenConnectionsDotString ++ "\n" ++ ChildrenDotString.

  -spec partinfo_to_dot(#per_part_abs_info{}) -> nonempty_string().
partinfo_to_dot(#per_part_abs_info{role = Role, commit_index = CI, voted_for_less = VFL, term = Term}) ->
  Prefix = "\t{"
    ++ erlang_to_string(Role) ++ " | "
    ++ "CI: " ++ erlang_to_string(CI) ++ " | "
    ++ "VFL: " ++ erlang_to_string(VFL) ++ " | ",
  TermString = case Term of
                 undefined -> "no term";
                 _ -> "Term: " ++ erlang_to_string(Term)
               end,
  Prefix ++ TermString ++ "}".

-spec dot_prefix() -> nonempty_string().
dot_prefix() ->
  "digraph AbsLogTrees { \n".

-spec dot_postfix() -> nonempty_string().
dot_postfix() ->
  "}".

-spec erlang_to_string(any()) -> string().
erlang_to_string(Erl) ->
  io_lib:format("~p", [Erl]).

-spec get_arrows_parent_to_children(nonempty_string(), non_neg_integer()) -> nonempty_string().
get_arrows_parent_to_children(ParentName, NumChildren) ->
  lists:foldl(
    fun(ChildNumber, Acc) ->
      Acc ++ "\n" ++ ParentName ++ " -> " ++ ParentName ++ erlang_to_string(ChildNumber) ++ ";"
    end,
    "",
    lists:seq(1, NumChildren)
  ).

comment_abslog_tree(AbsLogTree) ->
  "\n/*" ++ erlang_to_string(AbsLogTree) ++ "*/".