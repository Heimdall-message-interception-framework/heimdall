-record(instruction, {
    module :: atom(), % either message_interception_layer or SUT
    function :: atom(),
    args :: [any()]
}
).

-record(state, {
    properties :: #{atom() => boolean()},
    commands_in_transit :: [any()], % should have command type
    timeouts :: [any()], % timeout, assumed that is a tuple of {Proc, TimerRef, etc.} see MIL
    nodes :: [any()], % process_identifier
    crashed :: [any()] % process_identifier
}).

-type history() :: [{#instruction{}, #state{}}].


% -spec choose_instruction(any(), [instruction()], [instruction()], history()) -> instruction()
% choose_instruction(MIL, SUT_Instructions, Sched_Instructions, History) -> Instruction