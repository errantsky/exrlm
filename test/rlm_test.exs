defmodule RLMTest do
  use ExUnit.Case, async: false

  alias RLM.Test.MockLLM

  # The application starts the supervision tree automatically.
  # No manual setup needed for Registry, PubSub, or DynamicSupervisors.

  describe "RLM.run/3 - single iteration" do
    test "LLM sets final_answer immediately" do
      MockLLM.program_responses(self(), [
        MockLLM.mock_response("final_answer = String.length(context)")
      ])

      assert {:ok, 11, run_id} =
               RLM.run("Hello World", "Count the characters", llm_module: MockLLM)

      assert is_binary(run_id)
    end

    test "context is available in bindings" do
      MockLLM.program_responses(self(), [
        MockLLM.mock_response("final_answer = context")
      ])

      assert {:ok, "my input data", _run_id} =
               RLM.run("my input data", "Return context", llm_module: MockLLM)
    end
  end

  describe "RLM.run/3 - multi-iteration" do
    test "LLM explores then commits" do
      MockLLM.program_responses(self(), [
        MockLLM.mock_response(
          "line_count = context |> String.split(\"\\n\") |> length()\nIO.puts(\"Lines: \#{line_count}\")",
          "counting lines first"
        ),
        MockLLM.mock_response("final_answer = line_count", "returning the count")
      ])

      assert {:ok, 3, _run_id} =
               RLM.run("line 1\nline 2\nline 3", "Count the lines", llm_module: MockLLM)
    end

    test "bindings persist across iterations" do
      MockLLM.program_responses(self(), [
        MockLLM.mock_response("my_var = 42"),
        MockLLM.mock_response("final_answer = my_var * 2")
      ])

      assert {:ok, 84, _run_id} =
               RLM.run("test", "Test binding persistence", llm_module: MockLLM)
    end
  end

  describe "RLM.run/3 - error handling" do
    test "recovers from eval errors" do
      MockLLM.program_responses(self(), [
        MockLLM.mock_response("this_will_fail()", "trying something"),
        MockLLM.mock_response("final_answer = \"recovered\"", "fixing the error")
      ])

      assert {:ok, "recovered", _run_id} =
               RLM.run("test", "Test error recovery", llm_module: MockLLM)
    end

    test "respects max_iterations limit" do
      responses =
        List.duplicate(MockLLM.mock_response("IO.puts(\"still going\")"), 5)

      MockLLM.program_responses(self(), responses)

      assert {:error, msg} =
               RLM.run("test", "Never finishes",
                 llm_module: MockLLM,
                 max_iterations: 3
               )

      assert msg =~ "Maximum iterations"
    end

    test "handles empty code in response" do
      MockLLM.program_responses(self(), [
        MockLLM.mock_response("", "I'm thinking about this problem..."),
        MockLLM.mock_response("final_answer = \"got it\"", "now I know")
      ])

      assert {:ok, "got it", _run_id} =
               RLM.run("test", "Test empty code handling", llm_module: MockLLM)
    end
  end
end
