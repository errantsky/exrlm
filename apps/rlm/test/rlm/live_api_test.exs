defmodule RLM.LiveAPITest do
  @moduledoc """
  Integration test that calls the real Claude API.
  Requires CLAUDE_API_KEY env var to be set.
  Excluded from default test runs — use `mix test --include live_api` to run.
  """
  use ExUnit.Case, async: false

  @moduletag :live_api

  setup do
    api_key = System.get_env("CLAUDE_API_KEY")

    if is_nil(api_key) or api_key == "" do
      {:skip, "CLAUDE_API_KEY not set"}
    else
      :ok
    end
  end

  @tag timeout: 120_000
  test "end-to-end with Claude Haiku — simple computation" do
    result =
      RLM.run(
        "The quick brown fox jumps over the lazy dog",
        "Count the number of words in the context. Set final_answer to the integer count.",
        model_large: "claude-haiku-4-5-20251001",
        model_small: "claude-haiku-4-5-20251001",
        max_iterations: 5
      )

    assert {:ok, answer} = result
    assert answer == 9 or answer == "9" or (is_binary(answer) and String.contains?(answer, "9"))
  end
end
