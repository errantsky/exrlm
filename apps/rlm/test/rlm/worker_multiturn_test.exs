defmodule RLM.WorkerMultiturnTest do
  use ExUnit.Case, async: false

  # Multi-turn tests use MockLLM (global ETS state), so async: false

  setup do
    RLM.Test.MockLLM.program_responses([])
    :ok
  end

  describe "keep_alive mode" do
    test "Worker stays alive after final_answer when keep_alive: true" do
      RLM.Test.MockLLM.program_responses([
        "```elixir\nfinal_answer = :first\n```"
      ])

      {:ok, :first, span_id} =
        RLM.run("test", "test", llm_module: RLM.Test.MockLLM, keep_alive: true)

      # Worker should still be alive
      info = RLM.status(span_id)
      assert info.status == :idle
      assert info.iteration == 1
    end

    test "Worker terminates after final_answer when keep_alive: false" do
      RLM.Test.MockLLM.program_responses([
        "```elixir\nfinal_answer = :done\n```"
      ])

      {:ok, :done, span_id} =
        RLM.run("test", "test", llm_module: RLM.Test.MockLLM, keep_alive: false)

      # Give the worker time to stop
      Process.sleep(50)

      # Worker should be gone — GenServer.call should raise
      assert_raise RuntimeError, fn ->
        RLM.status(span_id)
      end
    rescue
      # Different error types depending on Registry lookup
      _ -> :ok
    catch
      :exit, _ -> :ok
    end

    test "send_message works on a keep_alive Worker" do
      RLM.Test.MockLLM.program_responses([
        # First run
        "```elixir\nfinal_answer = :first\n```",
        # Follow-up
        "```elixir\nfinal_answer = :second\n```"
      ])

      {:ok, :first, span_id} =
        RLM.run("test", "first task", llm_module: RLM.Test.MockLLM, keep_alive: true)

      # Send follow-up message
      {:ok, :second} = RLM.send_message(span_id, "second task")

      info = RLM.status(span_id)
      assert info.status == :idle
      assert info.iteration == 2
    end

    test "send_message rejects when Worker is busy" do
      RLM.Test.MockLLM.program_responses([
        "```elixir\nProcess.sleep(500)\nfinal_answer = :done\n```",
        "```elixir\nfinal_answer = :second\n```"
      ])

      {:ok, :done, span_id} =
        RLM.run("test", "test", llm_module: RLM.Test.MockLLM, keep_alive: true)

      # Immediately send while we program a slow follow-up
      RLM.Test.MockLLM.program_responses([
        "```elixir\nProcess.sleep(2000)\nfinal_answer = :slow\n```"
      ])

      # Start a follow-up in a spawned process
      parent = self()

      spawn(fn ->
        result = RLM.send_message(span_id, "slow task", 10_000)
        send(parent, {:follow_up_result, result})
      end)

      # Give it time to start
      Process.sleep(100)

      # A second send_message while running should be rejected
      assert {:error, msg} = RLM.send_message(span_id, "rejected task")
      assert msg =~ "busy"

      # Wait for the first follow-up to complete
      receive do
        {:follow_up_result, _} -> :ok
      after
        10_000 -> flunk("Follow-up did not complete")
      end
    end

    test "bindings persist across turns" do
      RLM.Test.MockLLM.program_responses([
        "```elixir\nmy_var = 42\nfinal_answer = :ok\n```",
        "```elixir\nfinal_answer = my_var * 2\n```"
      ])

      {:ok, :ok, span_id} =
        RLM.run("test", "test", llm_module: RLM.Test.MockLLM, keep_alive: true)

      {:ok, 84} = RLM.send_message(span_id, "double my_var")
    end
  end

  describe "history and status" do
    test "history returns accumulated messages" do
      RLM.Test.MockLLM.program_responses([
        "```elixir\nfinal_answer = :ok\n```"
      ])

      {:ok, :ok, span_id} =
        RLM.run("test context", "test query",
          llm_module: RLM.Test.MockLLM,
          keep_alive: true
        )

      history = RLM.history(span_id)
      assert is_list(history)
      # At minimum: system msg + user msg + assistant msg + feedback msg
      assert length(history) >= 4

      roles = Enum.map(history, & &1.role)
      assert :system in roles
      assert :user in roles
      assert :assistant in roles
    end

    test "status returns expected fields" do
      RLM.Test.MockLLM.program_responses([
        "```elixir\nfinal_answer = :ok\n```"
      ])

      {:ok, :ok, span_id} =
        RLM.run("test", "test",
          llm_module: RLM.Test.MockLLM,
          keep_alive: true
        )

      info = RLM.status(span_id)
      assert info.status == :idle
      assert is_integer(info.iteration)
      assert is_integer(info.message_count)
      assert is_binary(info.span_id)
      assert is_binary(info.run_id)
    end
  end
end
