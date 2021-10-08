% An SUT module encapsulates everything that the test engine needs to know about a specific
% system/application under test.
-module(sut_module).
-include("test_engine_types.hrl").

% behaviour callbacks
-callback bootstrap() -> any().
-callback generate_instruction(AbstrInstruction ::#abstract_instruction{} ) -> #instruction{}.
-callback get_instructions() -> [#abstract_instruction{}].
-callback get_observers() -> [atom()].