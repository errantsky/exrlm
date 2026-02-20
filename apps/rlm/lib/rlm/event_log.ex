defmodule RLM.EventLog do
  @moduledoc """
  Per-execution structured reasoning trace.
  Stores events and builds a tree representation for dashboard consumption.
  """
  use Agent

  defstruct [:run_id, :started_at, events: [], tree: %{}]

  def start_link(run_id) do
    Agent.start_link(
      fn ->
        %__MODULE__{
          run_id: run_id,
          started_at: System.monotonic_time(:microsecond),
          events: [],
          tree: %{}
        }
      end,
      name: via(run_id)
    )
  end

  def append(run_id, event) do
    Agent.update(via(run_id), fn log ->
      # Preserve timestamp_us if already stamped by EventLogHandler (wall-clock);
      # fall back to monotonic time only for direct callers that omit it.
      event = Map.put_new(event, :timestamp_us, System.monotonic_time(:microsecond))

      %{log | events: [event | log.events], tree: update_tree(log.tree, event)}
    end)
  rescue
    _ -> :ok
  end

  def get_tree(run_id) do
    Agent.get(via(run_id), & &1.tree)
  rescue
    _ -> %{}
  end

  def get_events(run_id) do
    Agent.get(via(run_id), fn log -> Enum.reverse(log.events) end)
  rescue
    _ -> []
  end

  def get_started_at(run_id) do
    Agent.get(via(run_id), & &1.started_at)
  rescue
    _ -> nil
  end

  @doc "Fall back to persisted store when the in-memory Agent has been swept."
  def get_events_from_store(run_id) do
    RLM.TraceStore.get_events(run_id)
  end

  def to_jsonl(run_id) do
    get_events(run_id)
    |> Enum.map(&sanitize_for_json/1)
    |> Enum.map(&Jason.encode!/1)
    |> Enum.join("\n")
  end

  defp sanitize_for_json(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {k, sanitize_value(v)} end)
  end

  defp sanitize_value(list) when is_list(list) do
    Enum.map(list, &sanitize_value/1)
  end

  defp sanitize_value(tuple) when is_tuple(tuple) do
    tuple |> Tuple.to_list() |> Enum.map(&sanitize_value/1)
  end

  defp sanitize_value(map) when is_map(map) do
    sanitize_for_json(map)
  end

  defp sanitize_value(value), do: value

  # Tree building

  defp update_tree(tree, %{type: :node_start} = event) do
    Map.put(tree, event.span_id, %{
      span_id: event.span_id,
      parent_span_id: event.parent_span_id,
      depth: event.depth,
      model: event.model,
      context_bytes: event[:context_bytes],
      status: :running,
      iterations: [],
      started_at: event.timestamp_us
    })
  end

  defp update_tree(tree, %{type: :iteration_stop} = event) do
    Map.update(tree, event.span_id, %{iterations: [event]}, fn node ->
      %{node | iterations: node.iterations ++ [event]}
    end)
  end

  defp update_tree(tree, %{type: :node_stop} = event) do
    Map.update(tree, event.span_id, %{}, fn node ->
      Map.merge(node, %{
        status: event.status,
        result_preview: event[:result_preview],
        duration_ms: event[:duration_ms],
        total_iterations: event[:total_iterations]
      })
    end)
  end

  defp update_tree(tree, _event), do: tree

  defp via(run_id), do: {:via, Registry, {RLM.Registry, {:event_log, run_id}}}
end
