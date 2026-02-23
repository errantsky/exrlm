defmodule RlmWebWeb.TraceDebugController do
  @moduledoc """
  Dev-only JSON API for trace inspection.

  Available only when `config :rlm_web, dev_routes: true` (see router.ex).
  """
  use RlmWebWeb, :controller

  def index(conn, _params) do
    run_ids = RLM.TraceStore.list_run_ids()
    json(conn, %{"run_ids" => run_ids})
  end

  def show(conn, %{"run_id" => run_id}) do
    events = RLM.TraceStore.get_events(run_id)

    sanitized =
      Enum.map(events, fn event ->
        event
        |> Map.take([
          :event,
          :span_id,
          :parent_span_id,
          :run_id,
          :depth,
          :iteration,
          :model,
          :status,
          :timestamp_us,
          :duration_ms,
          :code,
          :eval_status,
          :eval_result_preview,
          :stdout_preview,
          :stdout_bytes,
          :bindings_snapshot,
          :llm_prompt_tokens,
          :llm_completion_tokens,
          :cache_creation_input_tokens,
          :cache_read_input_tokens,
          :reasoning,
          :answer,
          :error,
          :total_iterations,
          :context_bytes,
          :query,
          :type
        ])
        |> Map.new(fn {k, v} -> {to_string(k), safe_json(v)} end)
      end)

    json(conn, %{"run_id" => run_id, "event_count" => length(sanitized), "events" => sanitized})
  end

  defp safe_json(v) when is_binary(v), do: v
  defp safe_json(v) when is_number(v), do: v
  defp safe_json(v) when is_atom(v), do: to_string(v)
  defp safe_json(v) when is_list(v), do: Enum.map(v, &safe_json/1)

  defp safe_json(v) when is_tuple(v),
    do: v |> Tuple.to_list() |> Enum.map(&safe_json/1)

  defp safe_json(v) when is_map(v),
    do: Map.new(v, fn {k, val} -> {to_string(k), safe_json(val)} end)

  defp safe_json(v), do: inspect(v)
end
