defmodule RLM.SkillIntegrationTest do
  use ExUnit.Case, async: false

  alias RLM.Test.MockLLM
  import RLM.Test.Helpers

  describe "activate_skill from eval'd code" do
    test "injects skill instructions into worker history" do
      MockLLM.program_responses([
        # First iteration: activate the skill
        MockLLM.mock_response(~s|{:ok, "dialectic"} = activate_skill("dialectic")|),
        # Second iteration: confirm skill was loaded
        MockLLM.mock_response("final_answer = :skill_activated")
      ])

      assert {:ok, :skill_activated, _run_id} =
               RLM.run("test", "Use the dialectic skill", llm_module: MockLLM)
    end

    test "list_skills returns available skills" do
      MockLLM.program_responses([
        MockLLM.mock_response(~s|IO.puts(list_skills())|),
        MockLLM.mock_response("final_answer = :done")
      ])

      assert {:ok, :done, _run_id} =
               RLM.run("test", "List skills", llm_module: MockLLM)
    end

    test "activate_skill is idempotent" do
      MockLLM.program_responses([
        MockLLM.mock_response(~s|{:ok, "dialectic"} = activate_skill("dialectic")|),
        MockLLM.mock_response(~s|{:ok, "dialectic"} = activate_skill("dialectic")|),
        MockLLM.mock_response("final_answer = :ok")
      ])

      assert {:ok, :ok, _run_id} =
               RLM.run("test", "Activate twice", llm_module: MockLLM)
    end

    test "activate_skill returns error for unknown skill" do
      MockLLM.program_responses([
        MockLLM.mock_response(~s|{:error, _} = activate_skill("nonexistent")|),
        MockLLM.mock_response("final_answer = :handled")
      ])

      assert {:ok, :handled, _run_id} =
               RLM.run("test", "Try unknown skill", llm_module: MockLLM)
    end
  end

  describe "pre-activated skills via opts" do
    test "skills option pre-loads instructions at startup" do
      MockLLM.program_responses([
        MockLLM.mock_response("final_answer = :done")
      ])

      assert {:ok, :done, _run_id} =
               RLM.run("test", "With pre-activated skill",
                 llm_module: MockLLM,
                 skills: ["dialectic"]
               )
    end

    test "unknown skill in opts is logged and skipped" do
      MockLLM.program_responses([
        MockLLM.mock_response("final_answer = :done")
      ])

      assert {:ok, :done, _run_id} =
               RLM.run("test", "With unknown pre-activated skill",
                 llm_module: MockLLM,
                 skills: ["nonexistent"]
               )
    end
  end

  describe "keep-alive session with skills" do
    test "skills available in interactive session" do
      MockLLM.program_responses([
        MockLLM.mock_response(~s|IO.puts(list_skills())|),
        MockLLM.mock_response("final_answer = :listed")
      ])

      {:ok, session_id} = RLM.start_session(llm_module: MockLLM)
      assert {:ok, :listed} = RLM.send_message(session_id, "List skills", 30_000)
    end

    test "pre-activated skills in session" do
      MockLLM.program_responses([
        MockLLM.mock_response("final_answer = :ready")
      ])

      {:ok, session_id} =
        RLM.start_session(llm_module: MockLLM, skills: ["dialectic"])

      assert {:ok, :ready} = RLM.send_message(session_id, "Ready?", 30_000)
    end
  end

  describe "worker status includes active skills" do
    test "status shows active skill names" do
      MockLLM.program_responses([
        MockLLM.mock_response("final_answer = :done")
      ])

      {:ok, session_id} =
        RLM.start_session(llm_module: MockLLM, skills: ["dialectic"])

      {:ok, status} = RLM.status(session_id)
      assert "dialectic" in status.active_skills
    end
  end

  describe "skill discovery at worker init" do
    test "subcall workers do not discover skills (depth > 0)" do
      # Subcall workers have depth > 0 and should skip skill discovery
      config = RLM.Config.load(llm_module: MockLLM)
      run_id = RLM.Span.generate_run_id()

      %{run_pid: run_pid} = start_test_run(run_id: run_id, config: config)

      MockLLM.program_responses([
        MockLLM.mock_response("final_answer = :subcall_done")
      ])

      worker_opts = [
        span_id: RLM.Span.generate_id(),
        run_id: run_id,
        context: "test",
        query: "test",
        config: config,
        depth: 1,
        model: config.model_small,
        caller: self()
      ]

      {:ok, _pid} = RLM.Run.start_worker(run_pid, worker_opts)

      assert_receive {:rlm_result, _, {:ok, :subcall_done}}, 10_000
    end
  end
end
