-module(html_output).
-include("test_engine_types.hrl").

-export([output_html/2]).

%%====================================================================
%% API functions
%%====================================================================

-spec output_html(nonempty_string(), history()) -> 'ok'.
output_html(Filename, History) ->
    % offload to separate process
    spawn(fun() -> 
        Html = history_to_html(Filename, History),
        write_file(Html, Filename ++ ".html") end
    ),
    ok.

%%====================================================================
%% Internal functions
%%====================================================================

-spec write_file(binary() | maybe_improper_list(binary() | maybe_improper_list(any(), binary() | []) | char(), binary() | []), atom() | binary() | [atom() | [any()] | char()]) -> 'ok' | {'error', atom()}.
write_file(String, Filename) ->
    io:format("[~p] Writing file ~p~n", [?MODULE, Filename]),
    file:write_file(Filename, unicode:characters_to_binary(String)).

-spec erlang_to_string(any()) -> string().
erlang_to_string(Erl) -> 
    io_lib:format("~p", [Erl]).

-spec history_to_html(nonempty_string(), history()) -> nonempty_string().
history_to_html(Name, History) ->
    Steps = lists:reverse(lists:seq(0, length(History) -1)),
    HistoryWithSteps = lists:reverse(lists:zip(Steps, History)),
    StepsAsHTML = lists:map(fun(S) -> step_to_html(S) end, HistoryWithSteps),
    AbstractStates = lists:foldl(fun({_Inst, State}, Acc) ->
        sets:add_element(State#prog_state.abstract_state, Acc) end, sets:new(), History),
    NumAbstractStates = sets:size(AbstractStates),
    html_prefix(Name) ++ 
    "
    <p>Number of abstract states: " ++ erlang_to_string(NumAbstractStates) ++ "</pe
    <ul class=\"list-group\">
        <li class=\"list-group-item\">
            <div class=\"header row\">
                <div class=\"col\">#</div>
                <div class=\"col\">instruction</div>
                <div class=\"col\">properties</div>
                <div class=\"col\">commands in transit</div>
                <div class=\"col\">nodes</div>
                <div class=\"col\">timeouts</div>
                <div class=\"col\">crashes</div>
            </div>
        </li>
        " ++ lists:flatten(StepsAsHTML) ++ "
        </ul>" ++
    html_postfix().

-spec step_to_html({integer(), {#instruction{}, #prog_state{}}}) -> nonempty_string().
step_to_html({Index, {#instruction{module= Module, function=Function, args= Args}, #prog_state{properties = Properties,
    commands_in_transit = CommandsInTransit,
    timeouts = Timeouts, nodes = Nodes, crashed = Crashed}}}) ->
        % format command name
        CommandName = io_lib:format("~p: ~p", [Module, Function]),
        % format properties
        PropertiesCount = maps:size(Properties),
        PropertiesValidCount = length(lists:filter(fun(X) -> X end, maps:values(Properties))),
        PropertiesFormatted = case PropertiesValidCount < PropertiesCount of
            true -> io_lib:format("<span class=\"prop-invalid\">~p</span>/~p", [PropertiesValidCount, PropertiesCount]);
            false -> io_lib:format("~p/~p", [PropertiesValidCount, PropertiesCount])
        end,
        Detailsname = "stepDetails"++erlang_to_string(Index),
"<li class=\"list-group-item li-collapsed clickable step\">
    <a class=\"toggle\" data-bs-toggle=\"collapse\" href=\"#"++Detailsname++"\" role=\"button\" aria-expanded=\"false\"
        aria-controls=\""++Detailsname++"\">"
    "<div class=\"row\">
                <div class=\"col\">"++ erlang_to_string(Index) ++"</div>
                <div class=\"col\">"++ CommandName ++ "</div>
                <div class=\"col\">"++ PropertiesFormatted ++ "</div>
                <div class=\"col\">"++ erlang_to_string(length(CommandsInTransit)) ++"</div>
                <div class=\"col\">"++ erlang_to_string(length(Nodes))++"</div>
                <div class=\"col\">"++ erlang_to_string(length(Timeouts))++"</div>
                <div class=\"col\">"++ erlang_to_string(length(Crashed))++"</div>
    </div></a>"
    "<div class=\"collapse\" id=\""++ Detailsname ++"\">
                <div class=\"card card-body details\">
                    <span class=\"state-property\">Instruction</span>
                    "++ instruction_to_string(#instruction{module= Module, function=Function, args= Args}) ++"
                    <span class=\"state-property\">Properties</span>
                    "++ erlang_to_string(Properties) ++ "
                    <span class=\"state-property\">Commands in Transit</span>
                    "++ cits_to_string(lists:reverse(CommandsInTransit)) ++"
                    <span class=\"state-property\">Nodes</span>
                    "++ nodelist_to_string(Nodes) ++"
                    <span class=\"state-property\">Timeouts</span>
                    "++ erlang_to_string(Timeouts) ++"
                    <span class=\"state-property\">Crashes</span>
                    "++ nodelist_to_string(Crashed) ++"
                </div>
            </div>
</li>".

instruction_to_string(#instruction{module= Module, function=Function, args= Args}) -> 
        "<span class=\"instruction\">"++erlang_to_string(Module) ++ ":" ++ erlang_to_string(Function) ++ args_to_string(Args) ++"</span>".

args_to_string(Args) ->
    Strings = lists:map(fun(A) -> case is_pid(A) of
        true -> pid_to_name(A);
        false -> erlang_to_string(A) end end, Args),
    "(" ++ string:join(Strings, ", ") ++ ")".

pid_to_name(Pid) ->
    case ets:lookup(pid_name_table, Pid) of
        [ ] -> erlang_to_string(Pid);
        [{_, Name}] ->
            Out = "<em class=\"pid\" title=\""++ erlang_to_string(Pid)++"\" data-bs-toggle=\"tooltip\" data-bs-placement=\"top\" data-pid=\""++ erlang_to_string(Pid)++"\" data-name=\""++ Name ++ "\">" ++ Name ++"</em>",
            io_lib:format("~s", [Out]) end.

cits_to_string(CommandsInTransit) ->
    "<ul>" ++
    lists:map(fun(C) -> "<li><span class=\"comm-in-trans\">" ++ cit_to_string(C) ++ "</span></li>"end,
        CommandsInTransit) ++
    "</ul>".

% {ID::any(), From::pid(), To::pid(), Module::atom(), Function::atom(), ListArgs::list(any())}
cit_to_string({ID, From, To, erlang, send, [_PIDTo, Msg]}) ->
    "[" ++ erlang_to_string(ID) ++ "] " ++ erlang_to_string(From) ++ " → " ++ erlang_to_string(To) ++ ": " ++ erlang_to_string(Msg);
cit_to_string(Command) ->
    erlang_to_string(Command).

nodelist_to_string(Nodes) ->
    Formatted = lists:map(fun(C) -> "<li>" ++ node_to_string(C) ++ "</li>" end, Nodes),
    "<ul class=\"nodelist\">" ++ Formatted ++ "</ul>".

node_to_string({_Name, PID}) ->
    pid_to_name(PID).
    


html_prefix(Title) ->
"<!doctype html>
<html lang=\"en\">

<head>
    <!-- Required meta tags -->
    <meta charset=\"utf-8\">
    <meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">

    <!-- Bootstrap CSS -->
    <link href=\"https://cdn.jsdelivr.net/npm/bootstrap@5.1.3/dist/css/bootstrap.min.css\" rel=\"stylesheet\"
        integrity=\"sha384-1BmE4kWBq78iYhFldvKuhfTAU6auU8tT94WrHftjDbrCEXSU1oBoqyl2QvZ6jIW3\" crossorigin=\"anonymous\">

    <title>"++ Title ++"</title>
    <style>
        tr:hover {
            background: rgb(137, 171, 235);
        }

        td a {
            display: block;
            border: 0px solid black;
            text-decoration: none;
            color: inherit;
        }

        td a:hover {
            color: inherit;
        }

        li a {
            display: block;
            border: 0px solid black;
            text-decoration: none;
            color: inherit;
        }

        li a:hover {
            color: inherit;
        }

        /* li.li-collapsed:hover { */
        li.clickable:hover {
            background: rgb(230, 230, 230);
        }

        .tr-hidden {
            max-height: 0;
            visibility: collapse;
            overflow: hidden;
            transition: visibility 0.2s ease-out;
        }

        .header {
            font-weight: bold;
        }

        .cell {
            width: 15%;
        }

        .details {
            margin-top: 5px;
        }

        .state-property {
            font-weight: bold;
        }

        .state-property::after {
            content: \":\";
        }

        .prop-invalid {
            color: red;
        }

        em.pid {
            font-style: inherit;
            color: blue;
            cursor: pointer;
        }

        ul.nodelist {
            padding-left: 0;
        }
        ul.nodelist li{
            display: inline;
        }
        ul.nodelist li:not(:last-child)::after {
            content: \" · \";
        }
    </style>
</head>

<body>
    <!-- Optional JavaScript; choose one of the two! -->

    <!-- Option 1: Bootstrap Bundle with Popper -->
    <!-- <script src=\"https://cdn.jsdelivr.net/npm/bootstrap@5.1.3/dist/js/bootstrap.bundle.min.js\" integrity=\"sha384-ka7Sk0Gln4gmtz2MlQnikT1wXgYsOg+OMhuP+IlRH9sENBO0LRn5q+8nbTov4+1p\" crossorigin=\"anonymous\"></script> -->

    <!-- Option 2: Separate Popper and Bootstrap JS -->
    <script src=\"https://cdn.jsdelivr.net/npm/@popperjs/core@2.10.2/dist/umd/popper.min.js\"
        integrity=\"sha384-7+zCNj/IqJ95wo16oMtfsKbZ9ccEh31eOz1HGyDuCQ6wgnyJNSYdrPa03rtR1zdB\"
        crossorigin=\"anonymous\"></script>
    <script src=\"https://cdn.jsdelivr.net/npm/bootstrap@5.1.3/dist/js/bootstrap.min.js\"
        integrity=\"sha384-QJHtvGhmr9XOIpI6YVutG+2QOK9T+ZnN4kzFN1RtK3zEFEIsxhlmWl5/YESvpZ13\"
        crossorigin=\"anonymous\"></script>
".

html_postfix() ->
"    <script>
        var toggle = document.getElementsByClassName(\"toggle\");
        var i;
        console.log(toggle.length);

        for (i = 0; i < toggle.length; i++) {
            toggle[i].addEventListener(\"click\", function () {
                var parent = this.closest('li');
                parent.classList.toggle('li-collapsed');
            });
        }

        // toggle tooltips
        var tooltipTriggerList = [].slice.call(document.querySelectorAll('[data-bs-toggle=\"tooltip\"]'))
        var tooltipList = tooltipTriggerList.map(function (tooltipTriggerEl) {
            return new bootstrap.Tooltip(tooltipTriggerEl)
        })

    </script>
</body>
</html>".