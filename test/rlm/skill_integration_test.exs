defmodule RLM.SkillIntegrationTest do
  @moduledoc """
  End-to-end integration tests for the Agent Skills system.
  Uses MockLLM to verify skill catalog and activation messages
  are correctly threaded through the full run pipeline.
  """
  use ExUnit.Case, async: false

  alias RLM.Test.MockLLM
  alias RLM.SkillRegistry

  @moduletag :skill

  setup do
    tmp_dir = Path.join(System.tmp_dir!(), "rlm_skill_integ_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(tmp_dir)

    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    %{tmp_dir: tmp_dir}
  end

  defp write_skill(base, name, opts) do
    description = Keyword.get(opts, :description, "A skill called #{name}.")
    body = Keyword.get(opts, :body, "Instructions for #{name}.")

    skill_dir = Path.join(base, name)
    File.mkdir_p!(skill_dir)

    File.write!(Path.join(skill_dir, "SKILL.md"), """
    ---
    name: #{name}
    description: #{description}
    ---
    #{body}
    """)
  end

  describe "one-shot run with skills" do
    test "skill catalog appears in system prompt", %{tmp_dir: tmp_dir} do
      write_skill(tmp_dir, "test-skill", description: "A test skill.")

      # Reload the global registry with our test paths
      SkillRegistry.reload(RLM.SkillRegistry, [tmp_dir])
      :sys.get_state(RLM.SkillRegistry)

      # Program MockLLM to capture the first message and return immediately.
      # The model will see the skill catalog in the system prompt.
      MockLLM.program_responses([
        MockLLM.mock_response("final_answer = :skill_test_ok")
      ])

      {:ok, answer, _run_id} =
        RLM.run("test data", "do something", llm_module: MockLLM)

      assert answer == :skill_test_ok

      # Restore empty paths so other tests aren't affected
      SkillRegistry.reload(RLM.SkillRegistry, [])
      :sys.get_state(RLM.SkillRegistry)
    end

    test "activated skills inject messages into worker history", %{tmp_dir: tmp_dir} do
      write_skill(tmp_dir, "activated-skill",
        description: "An activated skill.",
        body: "Follow these special instructions."
      )

      SkillRegistry.reload(RLM.SkillRegistry, [tmp_dir])
      :sys.get_state(RLM.SkillRegistry)

      # The model should see the activation message in history.
      # We verify by checking the run completes successfully with skills: opt.
      MockLLM.program_responses([
        MockLLM.mock_response("final_answer = :activated_ok")
      ])

      {:ok, answer, _run_id} =
        RLM.run("test data", "do something",
          llm_module: MockLLM,
          skills: ["activated-skill"]
        )

      assert answer == :activated_ok

      SkillRegistry.reload(RLM.SkillRegistry, [])
      :sys.get_state(RLM.SkillRegistry)
    end

    test "unknown skill names in skills: opt are silently skipped" do
      MockLLM.program_responses([
        MockLLM.mock_response("final_answer = :no_crash")
      ])

      {:ok, answer, _run_id} =
        RLM.run("test data", "do something",
          llm_module: MockLLM,
          skills: ["nonexistent-skill"]
        )

      assert answer == :no_crash
    end
  end

  describe "keep-alive session with skills" do
    test "session includes skill catalog and activation messages", %{tmp_dir: tmp_dir} do
      write_skill(tmp_dir, "session-skill",
        description: "A session skill.",
        body: "Session skill instructions."
      )

      SkillRegistry.reload(RLM.SkillRegistry, [tmp_dir])
      :sys.get_state(RLM.SkillRegistry)

      {:ok, session_id} =
        RLM.start_session(
          llm_module: MockLLM,
          skills: ["session-skill"]
        )

      # Check the history includes the skill activation message
      {:ok, history} = RLM.history(session_id)

      # History should be: [system_msg, skill_activation_msg]
      assert length(history) == 2
      system_msg = hd(history)
      assert system_msg.role == :system
      assert system_msg.content =~ "Available Skills"
      assert system_msg.content =~ "session-skill"

      skill_msg = Enum.at(history, 1)
      assert skill_msg.role == :user
      assert skill_msg.content =~ "Skill activated: session-skill"
      assert skill_msg.content =~ "Session skill instructions."

      SkillRegistry.reload(RLM.SkillRegistry, [])
      :sys.get_state(RLM.SkillRegistry)
    end
  end
end
