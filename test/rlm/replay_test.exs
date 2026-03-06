defmodule RLM.ReplayTest do
  @moduledoc """
  Tests for the deterministic replay feature.

  Covers: recording LLM responses, building tapes, replaying runs,
  and patching iterations during replay.
  """
  use ExUnit.Case, async: false

  alias RLM.Test.MockLLM
  import RLM.Test.Helpers

  # ── Phase 1: Recording ──────────────────────────────────────────────

  describe "recording LLM responses" do
    test "records llm_response events when enable_replay_recording is true" do
      MockLLM.program_responses([
        MockLLM.mock_response(~s(final_answer = "hello"))
      ])

      config = RLM.Config.load(llm_module: MockLLM, enable_replay_recording: true)
      run_id = RLM.Span.generate_run_id()
      span_id = RLM.Span.generate_id()

      %{run_pid: run_pid} = start_test_run(run_id: run_id, config: config)

      worker_opts = [
        span_id: span_id,
        run_id: run_id,
        context: "test context",
        query: "say hello",
        config: config,
        depth: 0,
        model: config.model_large,
        caller: self()
      ]

      {:ok, _pid} = RLM.Run.start_worker(run_pid, worker_opts)

      receive do
        {:rlm_result, ^span_id, {:ok, "hello"}} -> :ok
      after
        5000 -> flunk("Worker did not complete")
      end

      # Give events time to propagate
      Process.sleep(100)

      events = RLM.EventLog.get_events(run_id)
      llm_responses = Enum.filter(events, &(&1.type == :llm_response))

      assert length(llm_responses) == 1
      [resp] = llm_responses
      assert resp.iteration == 0
      assert is_binary(resp.response)
      assert is_map(resp.usage)
    end

    test "does NOT record llm_response events when enable_replay_recording is false" do
      MockLLM.program_responses([
        MockLLM.mock_response(~s(final_answer = "hello"))
      ])

      config = RLM.Config.load(llm_module: MockLLM, enable_replay_recording: false)
      run_id = RLM.Span.generate_run_id()
      span_id = RLM.Span.generate_id()

      %{run_pid: run_pid} = start_test_run(run_id: run_id, config: config)

      worker_opts = [
        span_id: span_id,
        run_id: run_id,
        context: "test context",
        query: "say hello",
        config: config,
        depth: 0,
        model: config.model_large,
        caller: self()
      ]

      {:ok, _pid} = RLM.Run.start_worker(run_pid, worker_opts)

      receive do
        {:rlm_result, ^span_id, {:ok, "hello"}} -> :ok
      after
        5000 -> flunk("Worker did not complete")
      end

      Process.sleep(100)

      events = RLM.EventLog.get_events(run_id)
      llm_responses = Enum.filter(events, &(&1.type == :llm_response))
      assert llm_responses == []
    end

    test "records multi-iteration LLM responses" do
      MockLLM.program_responses([
        MockLLM.mock_response("x = 1 + 2"),
        MockLLM.mock_response(~s(final_answer = "result: \#{x}"))
      ])

      config = RLM.Config.load(llm_module: MockLLM, enable_replay_recording: true)
      run_id = RLM.Span.generate_run_id()
      span_id = RLM.Span.generate_id()

      %{run_pid: run_pid} = start_test_run(run_id: run_id, config: config)

      worker_opts = [
        span_id: span_id,
        run_id: run_id,
        context: "test",
        query: "compute",
        config: config,
        depth: 0,
        model: config.model_large,
        caller: self()
      ]

      {:ok, _pid} = RLM.Run.start_worker(run_pid, worker_opts)

      receive do
        {:rlm_result, ^span_id, {:ok, _}} -> :ok
      after
        5000 -> flunk("Worker did not complete")
      end

      Process.sleep(100)

      events = RLM.EventLog.get_events(run_id)
      llm_responses = Enum.filter(events, &(&1.type == :llm_response))

      assert length(llm_responses) == 2
      assert Enum.map(llm_responses, & &1.iteration) == [0, 1]
    end

    test "records original context and query in node_start event for depth-0 workers" do
      MockLLM.program_responses([
        MockLLM.mock_response(~s(final_answer = "done"))
      ])

      config = RLM.Config.load(llm_module: MockLLM, enable_replay_recording: true)
      run_id = RLM.Span.generate_run_id()
      span_id = RLM.Span.generate_id()

      %{run_pid: run_pid} = start_test_run(run_id: run_id, config: config)

      worker_opts = [
        span_id: span_id,
        run_id: run_id,
        context: "my special context",
        query: "my special query",
        config: config,
        depth: 0,
        model: config.model_large,
        caller: self()
      ]

      {:ok, _pid} = RLM.Run.start_worker(run_pid, worker_opts)

      receive do
        {:rlm_result, ^span_id, {:ok, "done"}} -> :ok
      after
        5000 -> flunk("Worker did not complete")
      end

      Process.sleep(100)

      events = RLM.EventLog.get_events(run_id)
      node_start = Enum.find(events, &(&1.type == :node_start))

      assert node_start.original_context == "my special context"
      assert node_start.original_query == "my special query"
    end
  end

  # ── Phase 2: Tape ───────────────────────────────────────────────────

  describe "Tape.from_events/1" do
    test "builds a tape from recorded events" do
      MockLLM.program_responses([
        MockLLM.mock_response(~s(final_answer = "hello"))
      ])

      {:ok, "hello", run_id} =
        RLM.run("ctx", "say hello",
          llm_module: MockLLM,
          enable_replay_recording: true
        )

      Process.sleep(100)

      assert {:ok, tape} = RLM.Replay.Tape.from_events(run_id)
      assert tape.run_id == run_id
      assert length(tape.entries) == 1

      [entry] = tape.entries
      assert entry.iteration == 0
      assert is_binary(entry.response)
    end

    test "returns error for nonexistent run" do
      assert {:error, :no_events} = RLM.Replay.Tape.from_events("nonexistent_run")
    end

    test "returns error when no llm_response events exist" do
      # Run without recording enabled — events exist but no llm_response events
      MockLLM.program_responses([
        MockLLM.mock_response(~s(final_answer = "hello"))
      ])

      {:ok, "hello", run_id} =
        RLM.run("ctx", "say hello",
          llm_module: MockLLM,
          enable_replay_recording: false
        )

      Process.sleep(100)

      assert {:error, :no_responses} = RLM.Replay.Tape.from_events(run_id)
    end
  end

  # ── Phase 2: Replay LLM ─────────────────────────────────────────────

  describe "Replay.LLM" do
    test "returns responses in order from tape" do
      entries = [
        %{
          iteration: 0,
          span_id: "s1",
          response: ~s({"reasoning":"r0","code":"x=1"}),
          usage: %{
            prompt_tokens: 10,
            completion_tokens: 5,
            total_tokens: 15,
            cache_creation_input_tokens: nil,
            cache_read_input_tokens: nil
          }
        },
        %{
          iteration: 1,
          span_id: "s2",
          response: ~s({"reasoning":"r1","code":"final_answer=x"}),
          usage: %{
            prompt_tokens: 20,
            completion_tokens: 10,
            total_tokens: 30,
            cache_creation_input_tokens: nil,
            cache_read_input_tokens: nil
          }
        }
      ]

      tape = %RLM.Replay.Tape{run_id: "test", entries: entries}
      RLM.Replay.LLM.load_tape(tape)

      config = RLM.Config.load()
      {:ok, resp1, usage1} = RLM.Replay.LLM.chat([], "model", config)
      assert resp1 == ~s({"reasoning":"r0","code":"x=1"})
      assert usage1.prompt_tokens == 10

      {:ok, resp2, _usage2} = RLM.Replay.LLM.chat([], "model", config)
      assert resp2 == ~s({"reasoning":"r1","code":"final_answer=x"})
    end

    test "returns error when tape is exhausted" do
      tape = %RLM.Replay.Tape{run_id: "test", entries: []}
      RLM.Replay.LLM.load_tape(tape)

      config = RLM.Config.load()
      assert {:error, _} = RLM.Replay.LLM.chat([], "model", config)
    end
  end

  # ── Phase 3: Replay Orchestrator ────────────────────────────────────

  describe "replay/2" do
    test "replays a recorded run and produces the same result" do
      MockLLM.program_responses([
        MockLLM.mock_response(~s(final_answer = "hello"))
      ])

      {:ok, "hello", run_id} =
        RLM.run("test context", "say hello",
          llm_module: MockLLM,
          enable_replay_recording: true
        )

      Process.sleep(200)

      assert {:ok, "hello", replay_run_id} = RLM.Replay.replay(run_id)
      assert replay_run_id != run_id
    end

    test "replays a multi-iteration run" do
      MockLLM.program_responses([
        MockLLM.mock_response("x = 10 + 5"),
        MockLLM.mock_response(~s(final_answer = "sum is \#{x}"))
      ])

      {:ok, "sum is 15", run_id} =
        RLM.run("test", "compute",
          llm_module: MockLLM,
          enable_replay_recording: true
        )

      Process.sleep(200)

      assert {:ok, "sum is 15", _replay_run_id} = RLM.Replay.replay(run_id)
    end

    test "replay with patch modifies one iteration's code" do
      MockLLM.program_responses([
        MockLLM.mock_response(~s(final_answer = "original"))
      ])

      {:ok, "original", run_id} =
        RLM.run("ctx", "task",
          llm_module: MockLLM,
          enable_replay_recording: true
        )

      Process.sleep(200)

      assert {:ok, "patched", _replay_run_id} =
               RLM.Replay.replay(run_id,
                 patch: %{0 => ~s(final_answer = "patched")}
               )
    end

    test "replay returns error when no recorded events exist" do
      assert {:error, :no_events} = RLM.Replay.replay("nonexistent_run_id")
    end
  end

  # ── Phase 4: Public API ─────────────────────────────────────────────

  describe "RLM.replay/2 public API" do
    test "delegates to RLM.Replay.replay/2" do
      MockLLM.program_responses([
        MockLLM.mock_response(~s(final_answer = "via_api"))
      ])

      {:ok, "via_api", run_id} =
        RLM.run("ctx", "query",
          llm_module: MockLLM,
          enable_replay_recording: true
        )

      Process.sleep(200)

      assert {:ok, "via_api", _replay_run_id} = RLM.replay(run_id)
    end
  end
end
