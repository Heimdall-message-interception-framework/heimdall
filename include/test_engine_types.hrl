-record(instruction, {
    module :: atom(),
    function :: atom(),
    args :: [any()]
}
).

-type history() :: [{#instruction{}, #state{}}].

-record(state, {
    properties :: #{atom() => boolean()},
    commands_in_transit :: [command()],
    timeouts :: [timeout()],
    nodes :: [process_identifier()],
    crashed :: [process_identifier()]
}).

% -spec choose_instruction([instruction()], [instruction()], history()) -> instruction()
% choose_instruction(SUT_Instructions, Sched_Instructions, History) -> Instruction