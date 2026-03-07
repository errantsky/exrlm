defmodule RLMWeb.RunListLiveTest do
  use RLMWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias RLM.TraceStore

  setup do
    # Flush any pending put_event casts before wiping the table.
    _ = :sys.get_state(RLM.TraceStore)
    :dets.delete_all_objects(:rlm_traces)
    run_id = "test-run-#{System.unique_integer([:positive])}"
    %{run_id: run_id}
  end

  test "mounts and renders table headers", %{conn: conn} do
    {:ok, _lv, html} = live(conn, ~p"/")
    assert html =~ "Run ID"
    assert html =~ "Status"
    assert html =~ "Iterations"
    assert html =~ "Duration"
  end

  test "shows empty state when no runs", %{conn: conn} do
    {:ok, _lv, html} = live(conn, ~p"/")
    assert html =~ "No runs yet"
  end

  test "shows persisted run from TraceStore on mount", %{conn: conn, run_id: run_id} do
    TraceStore.put_event(run_id, %{
      type: :node_start,
      span_id: "span-1",
      parent_span_id: nil,
      depth: 0,
      model: "test-model",
      timestamp_us: System.monotonic_time(:microsecond)
    })

    # Flush the cast before mounting the LiveView
    _ = :sys.get_state(RLM.TraceStore)

    {:ok, _lv, html} = live(conn, ~p"/")
    assert html =~ String.slice(run_id, 0, 8)
  end

  test "new run row appears via PubSub node_start event", %{conn: conn, run_id: run_id} do
    {:ok, lv, _html} = live(conn, ~p"/")

    Phoenix.PubSub.broadcast(RLM.PubSub, "rlm:runs", %{
      event: [:rlm, :node, :start],
      metadata: %{
        run_id: run_id,
        span_id: "span-1",
        parent_span_id: nil,
        depth: 0,
        model: "claude-test"
      },
      measurements: %{},
      timestamp: System.monotonic_time(:microsecond)
    })

    # Let the handle_info propagate
    html = render(lv)
    assert html =~ String.slice(run_id, 0, 8)
  end

  test "run status updates to :ok via PubSub node_stop", %{conn: conn, run_id: run_id} do
    {:ok, lv, _html} = live(conn, ~p"/")

    # Seed a running run
    Phoenix.PubSub.broadcast(RLM.PubSub, "rlm:runs", %{
      event: [:rlm, :node, :start],
      metadata: %{run_id: run_id, span_id: "s1", parent_span_id: nil, depth: 0, model: "m"},
      measurements: %{},
      timestamp: System.monotonic_time(:microsecond)
    })

    Phoenix.PubSub.broadcast(RLM.PubSub, "rlm:runs", %{
      event: [:rlm, :node, :stop],
      metadata: %{run_id: run_id, span_id: "s1", depth: 0, status: :ok},
      measurements: %{duration_ms: 123},
      timestamp: System.monotonic_time(:microsecond)
    })

    html = render(lv)
    assert html =~ "ok"
  end

  test "keep-alive run status updates to :ok via PubSub turn_complete", %{
    conn: conn,
    run_id: run_id
  } do
    {:ok, lv, _html} = live(conn, ~p"/")

    # Seed a running keep-alive session
    Phoenix.PubSub.broadcast(RLM.PubSub, "rlm:runs", %{
      event: [:rlm, :node, :start],
      metadata: %{run_id: run_id, span_id: "s1", parent_span_id: nil, depth: 0, model: "m"},
      measurements: %{},
      timestamp: System.monotonic_time(:microsecond)
    })

    # Keep-alive sessions emit turn:complete instead of node:stop
    Phoenix.PubSub.broadcast(RLM.PubSub, "rlm:runs", %{
      event: [:rlm, :turn, :complete],
      metadata: %{run_id: run_id, span_id: "s1", depth: 0, status: :ok, result_preview: "done"},
      measurements: %{duration_ms: 5000, total_iterations: 3},
      timestamp: System.monotonic_time(:microsecond)
    })

    html = render(lv)
    assert html =~ "ok"
  end

  test "keep-alive run loads with correct status from TraceStore", %{
    conn: conn,
    run_id: run_id
  } do
    ts = System.system_time(:microsecond)

    TraceStore.put_event(run_id, %{
      type: :node_start,
      span_id: "span-ka",
      parent_span_id: nil,
      depth: 0,
      model: "test-model",
      timestamp_us: ts
    })

    TraceStore.put_event(run_id, %{
      type: :turn_complete,
      span_id: "span-ka",
      depth: 0,
      status: :ok,
      result_preview: "answer",
      duration_ms: 2000,
      total_iterations: 2,
      timestamp_us: ts + 1
    })

    _ = :sys.get_state(RLM.TraceStore)

    {:ok, _lv, html} = live(conn, ~p"/")
    assert html =~ String.slice(run_id, 0, 8)
    assert html =~ "ok"
  end
end
