defmodule RLM.PromptTest do
  use ExUnit.Case, async: true

  alias RLM.Prompt

  describe "build_system_message/0" do
    test "returns system role with content" do
      msg = Prompt.build_system_message()
      assert msg.role == :system
      assert is_binary(msg.content)
      assert msg.content =~ "RLM"
    end
  end

  describe "build_system_message/1" do
    test "depth 0 returns the root prompt (same as zero-arity)" do
      root = Prompt.build_system_message()
      depth0 = Prompt.build_system_message(depth: 0)

      assert root == depth0
    end

    test "depth > 0 returns the child prompt" do
      msg = Prompt.build_system_message(depth: 1)
      assert msg.role == :system
      assert msg.content =~ "child worker"
      assert msg.content =~ "Answer directly"
    end

    test "child prompt does not contain orchestration sections" do
      msg = Prompt.build_system_message(depth: 1)
      refute msg.content =~ "Monotonicity"
      refute msg.content =~ "Effort Triage"
      refute msg.content =~ "Interactive Mode"
      refute msg.content =~ "Structured Extraction"
      refute msg.content =~ "Concurrency"
    end

    test "child prompt still documents lm_query for legitimate deep recursion" do
      msg = Prompt.build_system_message(depth: 1)
      assert msg.content =~ "lm_query"
    end

    test "child prompt does not document parallel_query" do
      msg = Prompt.build_system_message(depth: 1)
      refute msg.content =~ "parallel_query"
    end

    test "child prompt includes filesystem tools" do
      msg = Prompt.build_system_message(depth: 1)
      assert msg.content =~ "read_file"
      assert msg.content =~ "write_file"
      assert msg.content =~ "bash"
      assert msg.content =~ "rg("
    end

    test "child prompt emphasizes fast termination" do
      msg = Prompt.build_system_message(depth: 1)
      assert msg.content =~ "as soon as you have the answer"
    end

    test "higher depths still get child prompt" do
      msg2 = Prompt.build_system_message(depth: 2)
      msg5 = Prompt.build_system_message(depth: 5)

      assert msg2.content =~ "child worker"
      assert msg5.content =~ "child worker"
    end
  end
end
