defmodule RLMWeb.RunDetailLive do
  use RLMWeb, :live_view

  import RLMWeb.TraceComponents

  alias Phoenix.PubSub

  @impl true
  def mount(%{"run_id" => run_id}, _session, socket) do
    if connected?(socket) do
      PubSub.subscribe(RLM.PubSub, "rlm:run:#{run_id}")
    end

    spans = load_spans(run_id)
    root_span_ids = root_span_ids(spans)

    {:ok,
     assign(socket,
       run_id: run_id,
       spans: spans,
       root_span_ids: root_span_ids,
       expanded: MapSet.new()
     )}
  end

  # --- PubSub handlers ---

  @impl true
  def handle_info(%{event: [:rlm, :node, :start], metadata: meta}, socket) do
    span = %{
      span_id: meta.span_id,
      parent_span_id: meta[:parent_span_id],
      depth: meta.depth,
      model: meta.model,
      context_bytes: meta[:context_bytes],
      status: :running,
      iterations: [],
      started_at: System.monotonic_time(:microsecond)
    }

    spans = Map.put(socket.assigns.spans, meta.span_id, span)

    {:noreply, assign(socket, spans: spans, root_span_ids: root_span_ids(spans))}
  end

  def handle_info(%{event: [:rlm, :node, :stop], metadata: meta, measurements: meas}, socket) do
    spans =
      Map.update(socket.assigns.spans, meta.span_id, %{}, fn node ->
        Map.merge(node, %{
          status: meta.status,
          result_preview: meta[:result_preview],
          duration_ms: meas[:duration_ms],
          total_iterations: meas[:total_iterations]
        })
      end)

    {:noreply, assign(socket, spans: spans)}
  end

  def handle_info(%{event: [:rlm, :iteration, :stop], metadata: meta, measurements: meas}, socket) do
    iter_event = %{
      type: :iteration_stop,
      span_id: meta.span_id,
      iteration: meta.iteration,
      duration_ms: meas[:duration_ms],
      code: meta[:code],
      stdout_preview: meta[:stdout_preview],
      stdout_bytes: meta[:stdout_bytes],
      eval_status: meta[:eval_status],
      bindings_snapshot: meta[:bindings_snapshot] || [],
      llm_prompt_tokens: meta[:llm_prompt_tokens],
      llm_completion_tokens: meta[:llm_completion_tokens]
    }

    spans =
      Map.update(socket.assigns.spans, meta.span_id, %{iterations: [iter_event]}, fn node ->
        %{node | iterations: (node[:iterations] || []) ++ [iter_event]}
      end)

    {:noreply, assign(socket, spans: spans)}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  # --- Events ---

  @impl true
  def handle_event("toggle_iteration", %{"span_id" => span_id, "index" => index_str}, socket) do
    key = {span_id, String.to_integer(index_str)}

    expanded =
      if MapSet.member?(socket.assigns.expanded, key) do
        MapSet.delete(socket.assigns.expanded, key)
      else
        MapSet.put(socket.assigns.expanded, key)
      end

    {:noreply, assign(socket, expanded: expanded)}
  end

  # --- Render ---

  @impl true
  def render(assigns) do
    ~H"""
    <div class="p-6">
      <div class="flex items-center gap-4 mb-6">
        <.link navigate={~p"/"} class="btn btn-ghost btn-sm">← Back</.link>
        <h1 class="text-xl font-bold font-mono">Run: {String.slice(@run_id, 0, 16)}</h1>
      </div>

      <div :if={map_size(@spans) == 0} class="text-base-content/50">
        No trace data found for this run.
      </div>

      <div class="space-y-2">
        <.span_node
          :for={root_id <- @root_span_ids}
          span={@spans[root_id]}
          spans={@spans}
          expanded={@expanded}
          depth={0}
        />
      </div>
    </div>
    """
  end

  # --- Helpers ---

  # Try the live EventLog Agent first (no-exit guard via Registry.lookup);
  # fall back to TraceStore for old/completed runs.
  defp load_spans(run_id) do
    case Registry.lookup(RLM.Registry, {:event_log, run_id}) do
      [{_pid, _}] ->
        RLM.EventLog.get_tree(run_id)

      [] ->
        RLM.TraceStore.get_events(run_id)
        |> Enum.reduce(%{}, &rebuild_tree/2)
    end
  end

  defp rebuild_tree(%{type: :node_start} = event, tree) do
    Map.put(tree, event.span_id, %{
      span_id: event.span_id,
      parent_span_id: event[:parent_span_id],
      depth: event[:depth],
      model: event[:model],
      context_bytes: event[:context_bytes],
      status: :running,
      iterations: [],
      started_at: event[:timestamp_us]
    })
  end

  defp rebuild_tree(%{type: :iteration_stop} = event, tree) do
    Map.update(tree, event.span_id, %{iterations: [event]}, fn node ->
      %{node | iterations: (node[:iterations] || []) ++ [event]}
    end)
  end

  defp rebuild_tree(%{type: :node_stop} = event, tree) do
    Map.update(tree, event.span_id, %{}, fn node ->
      Map.merge(node, %{
        status: event[:status],
        duration_ms: event[:duration_ms],
        total_iterations: event[:total_iterations]
      })
    end)
  end

  defp rebuild_tree(_event, tree), do: tree

  defp root_span_ids(spans) do
    spans
    |> Map.values()
    # Require :span_id to be present so partial maps created by out-of-order
    # :iteration_stop events (before their :node_start arrives) are excluded.
    |> Enum.filter(&(Map.has_key?(&1, :span_id) and is_nil(&1[:parent_span_id])))
    |> Enum.sort_by(& &1[:started_at])
    |> Enum.map(& &1.span_id)
  end
end
