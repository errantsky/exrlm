defmodule RlmWebWeb.RunDetailLiveTest do
  use RlmWebWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias RLM.TraceStore

  setup do
    :dets.delete_all_objects(:rlm_traces)
    :timer.sleep(20)
    run_id = "test-run-detail-#{System.unique_integer([:positive])}"
    span_id = "span-#{System.unique_integer([:positive])}"
    %{run_id: run_id, span_id: span_id}
  end

  test "mounts and shows 'no trace data' for unknown run", %{conn: conn} do
    {:ok, _lv, html} = live(conn, ~p"/runs/unknown-run-id")
    assert html =~ "No trace data found"
  end

  test "renders span tree from TraceStore on mount", %{
    conn: conn,
    run_id: run_id,
    span_id: span_id
  } do
    ts = System.monotonic_time(:microsecond)

    TraceStore.put_event(run_id, %{
      type: :node_start,
      span_id: span_id,
      parent_span_id: nil,
      depth: 0,
      model: "claude-test",
      timestamp_us: ts
    })

    TraceStore.put_event(run_id, %{
      type: :node_stop,
      span_id: span_id,
      depth: 0,
      status: :ok,
      duration_ms: 456,
      total_iterations: 2,
      timestamp_us: ts + 1
    })

    :timer.sleep(50)

    {:ok, _lv, html} = live(conn, ~p"/runs/#{run_id}")
    assert html =~ "span:" <> String.slice(span_id, 0, 6)
    assert html =~ "depth=0"
  end

  test "iteration row appears via PubSub", %{conn: conn, run_id: run_id, span_id: span_id} do
    # Seed a root span in TraceStore so the page has something to show
    TraceStore.put_event(run_id, %{
      type: :node_start,
      span_id: span_id,
      parent_span_id: nil,
      depth: 0,
      model: "m",
      timestamp_us: System.monotonic_time(:microsecond)
    })

    :timer.sleep(50)

    {:ok, lv, _html} = live(conn, ~p"/runs/#{run_id}")

    Phoenix.PubSub.broadcast(RLM.PubSub, "rlm:run:#{run_id}", %{
      event: [:rlm, :iteration, :stop],
      metadata: %{
        run_id: run_id,
        span_id: span_id,
        depth: 0,
        iteration: 1,
        code: "x = 1 + 1",
        stdout_preview: "",
        stdout_bytes: 0,
        eval_status: :ok,
        bindings_snapshot: [x: 2],
        llm_prompt_tokens: 100,
        llm_completion_tokens: 50
      },
      measurements: %{duration_ms: 200},
      timestamp: System.monotonic_time(:microsecond)
    })

    html = render(lv)
    assert html =~ "iter #1"
  end

  test "clicking iteration row toggles expanded code block", %{
    conn: conn,
    run_id: run_id,
    span_id: span_id
  } do
    TraceStore.put_event(run_id, %{
      type: :node_start,
      span_id: span_id,
      parent_span_id: nil,
      depth: 0,
      model: "m",
      timestamp_us: System.monotonic_time(:microsecond)
    })

    :timer.sleep(50)

    {:ok, lv, _html} = live(conn, ~p"/runs/#{run_id}")

    # Inject an iteration via PubSub
    Phoenix.PubSub.broadcast(RLM.PubSub, "rlm:run:#{run_id}", %{
      event: [:rlm, :iteration, :stop],
      metadata: %{
        run_id: run_id,
        span_id: span_id,
        depth: 0,
        iteration: 1,
        code: "result = :hello",
        stdout_preview: "hello output",
        stdout_bytes: 12,
        eval_status: :ok,
        bindings_snapshot: [],
        llm_prompt_tokens: nil,
        llm_completion_tokens: nil
      },
      measurements: %{duration_ms: 50},
      timestamp: System.monotonic_time(:microsecond)
    })

    # Collapsed: code not visible
    html = render(lv)
    refute html =~ "result = :hello"

    # Click to expand
    lv
    |> element("[phx-click='toggle_iteration'][phx-value-span_id='#{span_id}']")
    |> render_click()

    html = render(lv)
    assert html =~ "result = :hello"
    assert html =~ "hello output"
  end
end
