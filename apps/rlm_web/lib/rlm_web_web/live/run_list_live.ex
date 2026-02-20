defmodule RlmWebWeb.RunListLive do
  use RlmWebWeb, :live_view

  alias Phoenix.PubSub

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      PubSub.subscribe(RLM.PubSub, "rlm:runs")
    end

    runs = load_runs()
    {:ok, assign(socket, runs: runs)}
  end

  @impl true
  def handle_info(%{event: [:rlm, :node, :start], metadata: meta}, socket) do
    # Only create a new row for root spans (no parent)
    if is_nil(meta[:parent_span_id]) do
      run = %{
        run_id: meta.run_id,
        started_at: System.system_time(:microsecond),
        status: :running,
        depth: 0,
        iteration_count: 0,
        duration_ms: nil
      }

      runs = Map.put(socket.assigns.runs, meta.run_id, run)
      {:noreply, assign(socket, runs: runs)}
    else
      {:noreply, socket}
    end
  end

  def handle_info(%{event: [:rlm, :node, :stop], metadata: meta, measurements: meas}, socket) do
    # Only update the run summary row for the root span (depth 0)
    if meta[:depth] == 0 do
      runs =
        Map.update(socket.assigns.runs, meta.run_id, %{}, fn run ->
          %{run | status: meta.status, duration_ms: meas[:duration_ms]}
        end)

      {:noreply, assign(socket, runs: runs)}
    else
      {:noreply, socket}
    end
  end

  def handle_info(%{event: [:rlm, :iteration, :stop], metadata: meta}, socket) do
    runs =
      Map.update(socket.assigns.runs, meta.run_id, %{}, fn run ->
        %{run | iteration_count: (run[:iteration_count] || 0) + 1}
      end)

    {:noreply, assign(socket, runs: runs)}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  # Build run summaries from persisted TraceStore events.
  defp load_runs do
    RLM.TraceStore.list_run_ids()
    |> Enum.reduce(%{}, fn run_id, acc ->
      events = RLM.TraceStore.get_events(run_id)

      root_start =
        Enum.find(events, fn e ->
          e[:type] == :node_start and is_nil(e[:parent_span_id])
        end)

      root_stop =
        Enum.find(events, fn e ->
          e[:type] == :node_stop and e[:depth] == 0
        end)

      iter_count = Enum.count(events, &(&1[:type] == :iteration_stop))

      if root_start do
        Map.put(acc, run_id, %{
          run_id: run_id,
          started_at: root_start[:timestamp_us],
          status: if(root_stop, do: root_stop[:status], else: :running),
          depth: 0,
          iteration_count: iter_count,
          duration_ms: root_stop && root_stop[:duration_ms]
        })
      else
        acc
      end
    end)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="p-6">
      <h1 class="text-2xl font-bold mb-6">RLM Run History</h1>

      <table class="w-full border-collapse text-sm">
        <thead>
          <tr class="border-b border-base-300 text-left">
            <th class="py-2 pr-4 font-semibold">Run ID</th>
            <th class="py-2 pr-4 font-semibold">Started</th>
            <th class="py-2 pr-4 font-semibold">Status</th>
            <th class="py-2 pr-4 font-semibold">Iterations</th>
            <th class="py-2 pr-4 font-semibold">Duration</th>
          </tr>
        </thead>
        <tbody>
          <tr
            :for={{_id, run} <- Enum.sort_by(@runs, fn {_, r} -> r.started_at end, :desc)}
            class="border-b border-base-200 hover:bg-base-200 cursor-pointer"
            phx-click={JS.navigate(~p"/runs/#{run.run_id}")}
          >
            <td class="py-2 pr-4 font-mono">{String.slice(run.run_id, 0, 8)}</td>
            <td class="py-2 pr-4">{format_started_at(run.started_at)}</td>
            <td class="py-2 pr-4">
              <.status_badge status={run.status} />
            </td>
            <td class="py-2 pr-4">{run.iteration_count}</td>
            <td class="py-2 pr-4">{format_duration(run.duration_ms)}</td>
          </tr>
        </tbody>
      </table>

      <p :if={map_size(@runs) == 0} class="text-base-content/50 mt-4">
        No runs yet. Start one from IEx: <code>RLM.run("your prompt", "input")</code>
      </p>
    </div>
    """
  end

  defp status_badge(assigns) do
    ~H"""
    <span class={[
      "badge badge-sm",
      @status == :ok && "badge-success",
      @status == :running && "badge-warning",
      @status == :error && "badge-error"
    ]}>
      {@status}
    </span>
    """
  end

  defp format_started_at(nil), do: "—"

  defp format_started_at(wall_us) do
    offset_s = (System.system_time(:microsecond) - wall_us) / 1_000_000
    ago_s = round(offset_s)

    cond do
      ago_s < 60 -> "#{ago_s}s ago"
      ago_s < 3600 -> "#{div(ago_s, 60)}m ago"
      true -> "#{div(ago_s, 3600)}h ago"
    end
  end

  defp format_duration(nil), do: "—"
  defp format_duration(ms) when ms < 1000, do: "#{ms}ms"
  defp format_duration(ms), do: "#{Float.round(ms / 1000, 1)}s"
end
