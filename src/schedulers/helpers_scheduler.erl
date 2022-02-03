%%%-------------------------------------------------------------------
%%% @author fms
%%% @copyright (C) 2022, <COMPANY>
%%% @doc
%%%
%%% @end
%%% Created : 24. Jan 2022 10:46
%%%-------------------------------------------------------------------
-module(helpers_scheduler).
-author("fms").

-include("test_engine_types.hrl").

%% API
-export([get_args_from_command_for_mil/1, produce_d_tuple/2, choose_from_list/1, get_last_state_of_history/1, get_instruction_from_command/1, in_d_tuple/2, insert_elem_at_position_in_list/3, update_nth_list/3, change_elem_in_list/3]).

get_args_from_command_for_mil({Id, From, To, _Module, _Function, _Args}) ->
  [Id, From, To].

-spec get_last_state_of_history(history()) -> #prog_state{}.
get_last_state_of_history([]) ->
  #prog_state{};
get_last_state_of_history([{_Cmd, State} | _Tail]) ->
  State.

produce_d_tuple(SizeDTuple, NumPossibleDevPoints) when SizeDTuple =< NumPossibleDevPoints ->
%%  idea: produce all possible integers and draw list from them until full
  AllNumbers = lists:seq(0, NumPossibleDevPoints-1),
  Steps = lists:seq(0, SizeDTuple-1),
  HelperFunc = fun(_, {DTuple0, AllNumbers0}) ->
    NextElem = lists:nth(rand:uniform(length(AllNumbers0)), AllNumbers0),
    AllNumbers1 = lists:delete(NextElem, AllNumbers0),
    DTuple1 = [NextElem | DTuple0],
    {DTuple1, AllNumbers1}
               end,
  {DTuple, _} = lists:foldl(HelperFunc, {[], AllNumbers}, Steps),
  DTuple.

choose_from_list(List) ->
  choose_from_list(List, 5).

%% INTERNAL

choose_from_list(List, Trials) when Trials == 0 ->
%%  pick first; possible since the list cannot be empty
  [Element | _] = List,
  Element;
choose_from_list(List, Trials) when Trials > 0 ->
  HelperFunction = fun(X, Acc) ->
    case Acc of
      undefined -> RandomNumber = rand:uniform() * 4, % 75% chance to pick first command
        case RandomNumber < 3 of
          true -> X;
          false -> undefined
        end;
      Cmd       -> Cmd
    end
                   end,
  MaybeElement = lists:foldl(HelperFunction, undefined, List),
  case MaybeElement of
    undefined -> choose_from_list(List, Trials-1);
    Element -> Element
  end.

get_instruction_from_command(Command) ->
  Args = helpers_scheduler:get_args_from_command_for_mil(Command),
  #instruction{module = message_interception_layer, function = exec_msg_command, args = Args}.

-spec in_d_tuple(non_neg_integer(), list(non_neg_integer())) -> {found, non_neg_integer()} | notfound.
in_d_tuple(NumDevPoints, DTuple) ->
  HelperFunc = fun(X) -> X /= NumDevPoints end,
  SuffixDTuple = lists:dropwhile(HelperFunc, DTuple), % drops until it becomes NumDevPoints
  LenSuffix = length(SuffixDTuple),
  case LenSuffix == 0 of % predicate never got true so not in list,
    true -> notfound;
    false -> {found, length(DTuple) - LenSuffix + 1} % index from 0 % TODO: fix sth here
  end.

insert_elem_at_position_in_list(Position, Elem, List) ->
  rec_insert_elem_at_position_in_list(Position, Elem, [], List).

rec_insert_elem_at_position_in_list(Position, Elem, RevPrefix, Suffix) ->
  case Position of
    0 -> lists:append(lists:reverse(RevPrefix), [Elem | Suffix]);
    Pos1 -> case Suffix of
              [] -> erlang:throw("list out of bounds");
              [Head | Tail] -> rec_insert_elem_at_position_in_list(Pos1 - 1, Elem, [Head | RevPrefix], Tail)
            end
  end.

update_nth_list(1, [_|Rest], New) -> [New|Rest];
update_nth_list(I, [E|Rest], New) ->
  case length([E|Rest]) < I of
    true -> erlang:display(["Position", I, "List", [E|Rest]]);
    false -> [E|update_nth_list(I-1, Rest, New)]
  end.

change_elem_in_list(_Old, [], _New) -> [];
change_elem_in_list(Old, [E|Rest], New) ->
  [case E == Old of true -> New; false -> E end |
    change_elem_in_list(Old, Rest, New)].
