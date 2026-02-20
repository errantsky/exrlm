defmodule RLM.Agent.PromptTest do
  use ExUnit.Case, async: true

  alias RLM.Agent.Prompt

  describe "build/1" do
    test "starts with soul.md content" do
      soul_path = Application.app_dir(:rlm, "priv/soul.md")
      {:ok, soul} = File.read(soul_path)

      prompt = Prompt.build([])
      assert String.starts_with?(prompt, String.trim(soul))
    end

    test "includes agent instructions after soul content" do
      prompt = Prompt.build([])
      assert prompt =~ "expert Elixir coding agent"
      assert prompt =~ "## Guidelines"
      assert prompt =~ "## Tool usage"
    end

    test "uses provided :cwd in the prompt" do
      prompt = Prompt.build(cwd: "/tmp/test_project")
      assert prompt =~ "/tmp/test_project"
    end

    test "appends :extra instructions when provided" do
      prompt = Prompt.build(extra: "Never use GenServer.")
      assert prompt =~ "## Additional instructions"
      assert prompt =~ "Never use GenServer."
    end

    test "omits additional instructions section when no :extra given" do
      prompt = Prompt.build([])
      refute prompt =~ "## Additional instructions"
    end

    test "does not produce a leading blank line when soul.md is present" do
      prompt = Prompt.build([])
      refute String.starts_with?(prompt, "\n")
    end
  end
end
