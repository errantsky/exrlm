defmodule RLM.WorkerTest do
  use ExUnit.Case, async: false

  describe "subcall depth enforcement" do
    test "rejects spawn_subcall when max_depth is reached" do
      config =
        RLM.Config.load(
          llm_module: RLM.Test.MockLLM,
          max_depth: 0,
          max_iterations: 5
        )

      span_id = RLM.Span.generate_id()
      run_id = RLM.Span.generate_run_id()

      # Program a response with enough iterations to test
      RLM.Test.MockLLM.program_responses([
        # Sleep briefly inside eval so GenServer can handle calls during eval
        "```elixir\nProcess.sleep(200)\nfinal_answer = :done\n```"
      ])

      worker_opts = [
        span_id: span_id,
        run_id: run_id,
        context: "test",
        query: "test",
        config: config,
        depth: 0,
        model: config.model_large,
        caller: self()
      ]

      {:ok, pid} = DynamicSupervisor.start_child(RLM.WorkerSup, {RLM.Worker, worker_opts})

      # Wait for eval to start (worker is now in async eval, can handle calls)
      Process.sleep(50)

      result = GenServer.call(pid, {:spawn_subcall, "child query", :small})
      assert {:error, msg} = result
      assert msg =~ "Maximum recursion depth"

      # Wait for worker to finish
      receive do
        {:rlm_result, ^span_id, _} -> :ok
      after
        5000 -> flunk("Worker did not complete")
      end
    end
  end

  describe "subcall concurrency enforcement" do
    test "rejects spawn_subcall when max_concurrent_subcalls is 0" do
      config =
        RLM.Config.load(
          llm_module: RLM.Test.MockLLM,
          max_concurrent_subcalls: 0,
          max_depth: 5,
          max_iterations: 5
        )

      span_id = RLM.Span.generate_id()
      run_id = RLM.Span.generate_run_id()

      RLM.Test.MockLLM.program_responses([
        "```elixir\nProcess.sleep(200)\nfinal_answer = :done\n```"
      ])

      worker_opts = [
        span_id: span_id,
        run_id: run_id,
        context: "test",
        query: "test",
        config: config,
        depth: 0,
        model: config.model_large,
        caller: self()
      ]

      {:ok, pid} = DynamicSupervisor.start_child(RLM.WorkerSup, {RLM.Worker, worker_opts})

      # Wait for eval to start (worker can now handle calls)
      Process.sleep(50)

      result = GenServer.call(pid, {:spawn_subcall, "child query", :small})
      assert {:error, msg} = result
      assert msg =~ "Max concurrent subcalls"

      receive do
        {:rlm_result, ^span_id, _} -> :ok
      after
        5000 -> flunk("Worker did not complete")
      end
    end
  end

  describe "run/3 return value" do
    test "returns run_id as third element on success" do
      RLM.Test.MockLLM.program_responses([
        "```elixir\nfinal_answer = :ok\n```"
      ])

      assert {:ok, :ok, run_id} =
               RLM.run("test", "test", llm_module: RLM.Test.MockLLM)

      assert is_binary(run_id)
      assert String.length(run_id) > 0
    end

    test "returns error tuple (no run_id) on failure" do
      RLM.Test.MockLLM.program_responses(
        List.duplicate("```elixir\nIO.puts(\"looping\")\n```", 5)
      )

      result = RLM.run("test", "test", llm_module: RLM.Test.MockLLM, max_iterations: 2)
      assert {:error, _msg} = result
    end
  end
end
