defmodule RLM.WorkerTest do
  use ExUnit.Case, async: false

  alias RLM.Test.MockLLM
  import RLM.Test.Helpers

  describe "subcall depth enforcement" do
    test "rejects spawn_subcall when max_depth is reached" do
      config =
        RLM.Config.load(
          llm_module: MockLLM,
          max_depth: 0,
          max_iterations: 5
        )

      span_id = RLM.Span.generate_id()
      run_id = RLM.Span.generate_run_id()

      # Program a response with enough iterations to test
      MockLLM.program_responses([
        # Sleep briefly inside eval so GenServer can handle calls during eval
        MockLLM.mock_response("Process.sleep(200)\nfinal_answer = :done")
      ])

      %{run_pid: run_pid} = start_test_run(run_id: run_id, config: config)

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

      {:ok, pid} = RLM.Run.start_worker(run_pid, worker_opts)

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
          llm_module: MockLLM,
          max_concurrent_subcalls: 0,
          max_depth: 5,
          max_iterations: 5
        )

      span_id = RLM.Span.generate_id()
      run_id = RLM.Span.generate_run_id()

      MockLLM.program_responses([
        MockLLM.mock_response("Process.sleep(200)\nfinal_answer = :done")
      ])

      %{run_pid: run_pid} = start_test_run(run_id: run_id, config: config)

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

      {:ok, pid} = RLM.Run.start_worker(run_pid, worker_opts)

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

  describe "deadlock prevention (regression)" do
    test "Worker stays responsive while eval code calls lm_query" do
      # This is the core property the async-eval pattern protects:
      # eval runs in a separate Task, so when it calls lm_query() →
      # GenServer.call(worker_pid, {:spawn_subcall, ...}), the Worker
      # is free to handle the call. If eval were synchronous, this would
      # deadlock because the Worker would be blocked waiting for eval to
      # finish while eval is blocked waiting for the Worker to respond.

      parent_code =
        MockLLM.mock_response(
          ~s|{:ok, result} = lm_query("sub question", model_size: :small)\nfinal_answer = "got: " <> result|,
          "testing subcall from eval"
        )

      MockLLM.program_responses([parent_code])

      # Use a tight timeout — a deadlock would hang forever
      assert {:ok, "got: default mock answer", _run_id} =
               RLM.run("test", "deadlock test",
                 llm_module: MockLLM,
                 max_depth: 3,
                 eval_timeout: 5_000
               )
    end

    test "Worker handles concurrent subcalls from parallel_query without deadlock" do
      # parallel_query spawns multiple Task.async calls that each call
      # GenServer.call(worker_pid, {:spawn_subcall, ...}) concurrently.
      # All must succeed without deadlocking.

      parent_code =
        MockLLM.mock_response(
          ~s|results = parallel_query(["q1", "q2", "q3"])\nfinal_answer = length(results)|,
          "parallel subcalls"
        )

      MockLLM.program_responses([parent_code])

      assert {:ok, 3, _run_id} =
               RLM.run("test", "parallel deadlock test",
                 llm_module: MockLLM,
                 max_depth: 3,
                 eval_timeout: 5_000
               )
    end

    test "Worker handles direct_query from eval without deadlock" do
      schema = %{
        "type" => "object",
        "properties" => %{"v" => %{"type" => "string"}},
        "required" => ["v"],
        "additionalProperties" => false
      }

      schema_code = inspect(schema)

      parent_code =
        MockLLM.mock_response(
          ~s|{:ok, result} = lm_query("extract", schema: #{schema_code})\nfinal_answer = result|,
          "direct query from eval"
        )

      MockLLM.program_responses([
        parent_code,
        MockLLM.mock_direct_response(%{"v" => "hello"}, schema)
      ])

      assert {:ok, %{"v" => "hello"}, _run_id} =
               RLM.run("test", "direct query deadlock test",
                 llm_module: MockLLM,
                 max_depth: 3,
                 eval_timeout: 5_000
               )
    end
  end

  describe "run-scoped cascade shutdown" do
    test "killing the Run terminates all workers" do
      config =
        RLM.Config.load(
          llm_module: MockLLM,
          max_depth: 5,
          max_iterations: 50
        )

      # Program a slow worker so we can kill the Run while it's running
      MockLLM.program_responses([
        MockLLM.mock_response("Process.sleep(5000)\nfinal_answer = :never_reached")
      ])

      span_id = RLM.Span.generate_id()
      run_id = RLM.Span.generate_run_id()

      %{run_pid: run_pid} = start_test_run(run_id: run_id, config: config)

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

      {:ok, worker_pid} = RLM.Run.start_worker(run_pid, worker_opts)

      # Wait for eval to start
      Process.sleep(50)
      assert Process.alive?(worker_pid)

      # Kill the Run — should cascade to all workers
      DynamicSupervisor.terminate_child(RLM.RunSup, run_pid)

      Process.sleep(50)
      refute Process.alive?(worker_pid)
      refute Process.alive?(run_pid)
    end
  end

  describe "run/3 return value" do
    test "returns run_id as third element on success" do
      MockLLM.program_responses([
        MockLLM.mock_response("final_answer = :ok")
      ])

      assert {:ok, :ok, run_id} =
               RLM.run("test", "test", llm_module: MockLLM)

      assert is_binary(run_id)
      assert String.length(run_id) > 0
    end

    test "returns error tuple (no run_id) on failure" do
      MockLLM.program_responses(List.duplicate(MockLLM.mock_response("IO.puts(\"looping\")"), 5))

      result = RLM.run("test", "test", llm_module: MockLLM, max_iterations: 2)
      assert {:error, _msg} = result
    end
  end
end
