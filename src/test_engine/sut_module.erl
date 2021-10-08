% An SUT module encapsulates everything that the test engine needs to know about a specific
% system/application under test.
-module(sut_module).
-include("test_engine_types.hrl").

% behaviour callbacks
-callback bootstrap(Config :: any()) -> Config :: any().
-callback generate_instruction(AbstrInstruction ::#abstract_instruction{},
    Config :: any()) -> {#instruction{}, Config :: any()}.
-callback get_instructions(Config :: any()) -> [#abstract_instruction{}].
-callback get_observers(Config :: any()) -> [atom()].