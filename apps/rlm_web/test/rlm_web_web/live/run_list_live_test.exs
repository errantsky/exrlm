defmodule RlmWebWeb.RunListLiveTest do
  use RlmWebWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias RLM.TraceStore

  setup do
    # Clear all dets data — safe because async: false means sequential tests
    :dets.delete_all_objects(:rlm_traces)
    :timer.sleep(20)
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

    # Allow cast to flush
    :timer.sleep(50)

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
end
