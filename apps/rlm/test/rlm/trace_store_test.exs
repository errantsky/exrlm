defmodule RLM.TraceStoreTest do
  use ExUnit.Case, async: false

  setup do
    # Clear all records between tests to avoid cross-contamination
    :dets.delete_all_objects(:rlm_traces)
    :ok
  end

  describe "put_event/2 + get_events/1" do
    test "round-trips an event for a given run_id" do
      run_id = "run-#{System.unique_integer([:positive])}"

      event = %{
        type: :node_start,
        span_id: "span-1",
        timestamp_us: System.monotonic_time(:microsecond)
      }

      RLM.TraceStore.put_event(run_id, event)

      # cast is async, give it a moment to process
      Process.sleep(50)

      events = RLM.TraceStore.get_events(run_id)
      assert length(events) == 1
      assert hd(events).type == :node_start
      assert hd(events).span_id == "span-1"
    end

    test "returns events in chronological order" do
      run_id = "run-#{System.unique_integer([:positive])}"
      now = System.monotonic_time(:microsecond)

      event1 = %{type: :node_start, span_id: "span-1", timestamp_us: now}
      event2 = %{type: :iteration_stop, span_id: "span-1", timestamp_us: now + 1_000}
      event3 = %{type: :node_stop, span_id: "span-1", timestamp_us: now + 2_000}

      RLM.TraceStore.put_event(run_id, event3)
      RLM.TraceStore.put_event(run_id, event1)
      RLM.TraceStore.put_event(run_id, event2)
      Process.sleep(50)

      events = RLM.TraceStore.get_events(run_id)
      assert length(events) == 3
      assert Enum.map(events, & &1.type) == [:node_start, :iteration_stop, :node_stop]
    end

    test "returns empty list for unknown run_id" do
      assert RLM.TraceStore.get_events("nonexistent") == []
    end
  end

  describe "list_run_ids/0" do
    test "returns inserted run IDs" do
      run_a = "run-a-#{System.unique_integer([:positive])}"
      run_b = "run-b-#{System.unique_integer([:positive])}"
      now = System.monotonic_time(:microsecond)

      RLM.TraceStore.put_event(run_a, %{type: :node_start, timestamp_us: now})
      RLM.TraceStore.put_event(run_b, %{type: :node_start, timestamp_us: now})
      # Insert a second event for run_a to verify deduplication
      RLM.TraceStore.put_event(run_a, %{type: :node_stop, timestamp_us: now + 1_000})
      Process.sleep(50)

      run_ids = RLM.TraceStore.list_run_ids()
      assert run_a in run_ids
      assert run_b in run_ids
    end

    test "returns empty list when no data" do
      assert RLM.TraceStore.list_run_ids() == []
    end
  end

  describe "delete_older_than/1" do
    test "removes old records but keeps recent ones" do
      run_id = "run-#{System.unique_integer([:positive])}"
      now = System.monotonic_time(:microsecond)

      old_event = %{type: :node_start, span_id: "old", timestamp_us: now - 10_000_000}
      new_event = %{type: :node_stop, span_id: "new", timestamp_us: now}

      RLM.TraceStore.put_event(run_id, old_event)
      RLM.TraceStore.put_event(run_id, new_event)
      Process.sleep(50)

      # Delete events older than 5 seconds ago
      cutoff = now - 5_000_000
      RLM.TraceStore.delete_older_than(cutoff)

      events = RLM.TraceStore.get_events(run_id)
      assert length(events) == 1
      assert hd(events).span_id == "new"
    end
  end
end
