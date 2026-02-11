defmodule RLMTest do
  use ExUnit.Case, async: false

  # The application starts the supervision tree automatically.
  # No manual setup needed for Registry, PubSub, or DynamicSupervisors.

  describe "RLM.run/3 - single iteration" do
    test "LLM sets final_answer immediately" do
      RLM.Test.MockLLM.program_responses(self(), [
        "```elixir\nfinal_answer = String.length(context)\n```"
      ])

      result = RLM.run("Hello World", "Count the characters", llm_module: RLM.Test.MockLLM)
      assert {:ok, 11} = result
    end

    test "context is available in bindings" do
      RLM.Test.MockLLM.program_responses(self(), [
        "```elixir\nfinal_answer = context\n```"
      ])

      result = RLM.run("my input data", "Return context", llm_module: RLM.Test.MockLLM)
      assert {:ok, "my input data"} = result
    end
  end

  describe "RLM.run/3 - multi-iteration" do
    test "LLM explores then commits" do
      RLM.Test.MockLLM.program_responses(self(), [
        "```elixir\nline_count = context |> String.split(\"\\n\") |> length()\nIO.puts(\"Lines: \#{line_count}\")\n```",
        "```elixir\nfinal_answer = line_count\n```"
      ])

      result = RLM.run("line 1\nline 2\nline 3", "Count the lines", llm_module: RLM.Test.MockLLM)
      assert {:ok, 3} = result
    end

    test "bindings persist across iterations" do
      RLM.Test.MockLLM.program_responses(self(), [
        "```elixir\nmy_var = 42\n```",
        "```elixir\nfinal_answer = my_var * 2\n```"
      ])

      result = RLM.run("test", "Test binding persistence", llm_module: RLM.Test.MockLLM)
      assert {:ok, 84} = result
    end
  end

  describe "RLM.run/3 - error handling" do
    test "recovers from eval errors" do
      RLM.Test.MockLLM.program_responses(self(), [
        "```elixir\nthis_will_fail()\n```",
        "```elixir\nfinal_answer = \"recovered\"\n```"
      ])

      result = RLM.run("test", "Test error recovery", llm_module: RLM.Test.MockLLM)
      assert {:ok, "recovered"} = result
    end

    test "respects max_iterations limit" do
      responses = List.duplicate("```elixir\nIO.puts(\"still going\")\n```", 5)
      RLM.Test.MockLLM.program_responses(self(), responses)

      result =
        RLM.run("test", "Never finishes",
          llm_module: RLM.Test.MockLLM,
          max_iterations: 3
        )

      assert {:error, msg} = result
      assert msg =~ "Maximum iterations"
    end

    test "handles no code block in response" do
      RLM.Test.MockLLM.program_responses(self(), [
        "I'm thinking about this problem...",
        "```elixir\nfinal_answer = \"got it\"\n```"
      ])

      result = RLM.run("test", "Test no code block handling", llm_module: RLM.Test.MockLLM)
      assert {:ok, "got it"} = result
    end
  end
end
