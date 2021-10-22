% An SUT module encapsulates everything that the test engine needs to know about a specific
% system/application under test.
-module(sut_module).
-include("test_engine_types.hrl").

% behaviour callbacks
-callback start_link(Config :: any()) -> 'ignore' | {'error', _} | {'ok', pid()}.
-callback start(Config :: any()) -> 'ignore' | {'error', _} | {'ok', pid()}.
-callback bootstrap_wo_scheduler() -> any().
-callback needs_bootstrap_w_scheduler() -> boolean().
-callback bootstrap_w_scheduler(TestEngine :: pid()) -> boolean().
-callback stop_sut() -> ok | {error, _}.
-callback generate_instruction(AbstrInstruction ::#abstract_instruction{}) -> #instruction{}.
-callback get_instructions() -> [#abstract_instruction{}].
-callback get_observers() -> [atom()].
% -callback run_instruction(AbstrInstruction ::#abstract_instruction{}) -> any().
