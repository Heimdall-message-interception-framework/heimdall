-record(instruction, {
    module :: atom(), % either message_interception_layer or SUT
    function :: atom(),
    args :: [any()]
}).

-record(abstract_instruction, {
    module :: atom(),
    function :: atom()
}).

-record(prog_state, {
    properties = maps:new() :: #{nonempty_string() => boolean()},
    commands_in_transit = [] :: [any()], % should have command type
    timeouts = [] :: [any()], % timeout, see MIL
    nodes = [] :: [pid()], % process_identifier
    crashed = [] :: [pid()], % process_identifier
    abstract_state = undefined :: undefined | any() % datastructure to hold abstract state
}).

-type history() :: [{#instruction{}, #prog_state{}}].


% -spec choose_instruction(any(), [instruction()], [instruction()], history()) -> instruction()
% choose_instruction(MIL, SUT_Instructions, Sched_Instructions, History) -> Instruction