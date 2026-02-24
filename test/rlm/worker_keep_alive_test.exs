defmodule RLM.WorkerKeepAliveTest do
  use ExUnit.Case, async: false

  alias RLM.Test.MockLLM
  import RLM.Test.Helpers

  defp start_keep_alive_worker(extra_opts \\ []) do
    span_id = RLM.Span.generate_id()

    config =
      RLM.Config.load(
        Keyword.merge(
          [llm_module: MockLLM, max_iterations: 10],
          extra_opts
        )
      )

    %{run_pid: run_pid, run_id: run_id} =
      start_test_run(config: config, keep_alive: true)

    worker_opts = [
      span_id: span_id,
      run_id: run_id,
      config: config,
      keep_alive: true,
      cwd: System.tmp_dir!()
    ]

    {:ok, pid} = RLM.Run.start_worker(run_pid, worker_opts)
    via = {:via, Registry, {RLM.Registry, {:worker, span_id}}}

    %{pid: pid, via: via, span_id: span_id, run_id: run_id}
  end

  describe "keep_alive mode" do
    test "Worker starts in :idle status" do
      %{via: via} = start_keep_alive_worker()
      status = GenServer.call(via, :status)
      assert status.status == :idle
      assert status.keep_alive == true
    end

    test "Worker stays alive after final_answer" do
      MockLLM.program_responses([
        MockLLM.mock_response("final_answer = :first_turn")
      ])

      %{via: via, pid: pid} = start_keep_alive_worker()

      assert {:ok, :first_turn} = GenServer.call(via, {:send_message, "turn 1"}, 5000)
      assert Process.alive?(pid)

      status = GenServer.call(via, :status)
      assert status.status == :idle
    end

    test "bindings persist across turns" do
      MockLLM.program_responses([
        # Turn 1: set a variable
        MockLLM.mock_response("my_var = 42\nfinal_answer = :turn1_done"),
        # Turn 2: use the persisted variable
        MockLLM.mock_response("final_answer = my_var + 1")
      ])

      %{via: via} = start_keep_alive_worker()

      assert {:ok, :turn1_done} = GenServer.call(via, {:send_message, "set var"}, 5000)
      assert {:ok, 43} = GenServer.call(via, {:send_message, "use var"}, 5000)
    end

    test "final_answer resets between turns" do
      MockLLM.program_responses([
        MockLLM.mock_response("final_answer = :answer_1"),
        # This should start with final_answer = nil
        MockLLM.mock_response("final_answer = :answer_2")
      ])

      %{via: via} = start_keep_alive_worker()

      assert {:ok, :answer_1} = GenServer.call(via, {:send_message, "turn 1"}, 5000)
      assert {:ok, :answer_2} = GenServer.call(via, {:send_message, "turn 2"}, 5000)
    end

    test "rejects concurrent send_message while busy" do
      MockLLM.program_responses([
        # Slow response so we can test concurrent rejection
        MockLLM.mock_response("Process.sleep(200)\nfinal_answer = :done")
      ])

      %{via: via} = start_keep_alive_worker()

      # Start an async call
      task =
        Task.async(fn ->
          GenServer.call(via, {:send_message, "slow turn"}, 5000)
        end)

      # Give it time to start processing
      Process.sleep(50)

      # Should be rejected — Worker is busy
      assert {:error, "Worker is busy"} = GenServer.call(via, {:send_message, "concurrent"})

      # The first call should complete fine
      assert {:ok, :done} = Task.await(task, 5000)
    end

    test "history accumulates across turns" do
      MockLLM.program_responses([
        MockLLM.mock_response("final_answer = :t1"),
        MockLLM.mock_response("final_answer = :t2")
      ])

      %{via: via} = start_keep_alive_worker()

      GenServer.call(via, {:send_message, "turn 1"}, 5000)
      GenServer.call(via, {:send_message, "turn 2"}, 5000)

      history = GenServer.call(via, :history)

      # Should have system msg + user msg 1 + assistant + feedback + user msg 2 + assistant + feedback
      assert length(history) >= 5

      # Check that both user messages are present
      user_messages =
        Enum.filter(history, fn %{role: role} -> role == :user end)
        |> Enum.map(& &1.content)

      assert Enum.any?(user_messages, &(&1 =~ "turn 1"))
      assert Enum.any?(user_messages, &(&1 =~ "turn 2"))
    end

    test "status returns correct state" do
      %{via: via, span_id: span_id, run_id: run_id} = start_keep_alive_worker()

      status = GenServer.call(via, :status)
      assert status.session_id == span_id
      assert status.run_id == run_id
      assert status.status == :idle
      assert status.iteration == 0
      assert status.keep_alive == true
      assert is_binary(status.cwd)
    end

    test "iteration counter resets per turn" do
      MockLLM.program_responses([
        # Turn 1: 2 iterations before final_answer
        MockLLM.mock_response("IO.puts(:loop_1)"),
        MockLLM.mock_response("final_answer = :t1"),
        # Turn 2: starts from iteration 0 again
        MockLLM.mock_response("final_answer = :t2")
      ])

      %{via: via} = start_keep_alive_worker()

      assert {:ok, :t1} = GenServer.call(via, {:send_message, "turn 1"}, 5000)

      # After turn completes, iteration resets to 0
      status = GenServer.call(via, :status)
      assert status.iteration == 0

      assert {:ok, :t2} = GenServer.call(via, {:send_message, "turn 2"}, 5000)
    end

    test "max_iterations is per-turn, not lifetime" do
      MockLLM.program_responses([
        # Turn 1: use all 2 iterations, no final_answer → error
        MockLLM.mock_response("IO.puts(:iter_1)"),
        MockLLM.mock_response("IO.puts(:iter_2)"),
        # Turn 2: fresh budget, can succeed
        MockLLM.mock_response("final_answer = :recovered")
      ])

      %{via: via} = start_keep_alive_worker(max_iterations: 2)

      # Turn 1 exhausts its per-turn budget
      assert {:error, _} = GenServer.call(via, {:send_message, "exhaust budget"}, 5000)

      # Turn 2 gets a fresh iteration budget
      assert {:ok, :recovered} = GenServer.call(via, {:send_message, "fresh turn"}, 5000)
    end
  end
end
