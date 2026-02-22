defmodule RLM.Telemetry.Logger do
  @moduledoc """
  Structured logging handler for RLM telemetry events.
  """
  require Logger

  def handle_event([:rlm, :node, :start], _measurements, metadata, _config) do
    Logger.info("[RLM] Node started",
      span_id: metadata.span_id,
      depth: metadata.depth,
      model: metadata.model,
      context_bytes: metadata[:context_bytes]
    )
  end

  def handle_event([:rlm, :node, :stop], measurements, metadata, _config) do
    Logger.info("[RLM] Node completed",
      span_id: metadata.span_id,
      depth: metadata.depth,
      status: metadata.status,
      duration_ms: measurements.duration_ms,
      total_iterations: measurements.total_iterations
    )
  end

  def handle_event([:rlm, :iteration, :stop], measurements, metadata, _config) do
    Logger.debug("[RLM] Iteration #{metadata.iteration} completed",
      span_id: metadata.span_id,
      duration_ms: measurements.duration_ms,
      eval_status: metadata.eval_status
    )
  end

  def handle_event([:rlm, :llm, :request, :stop], measurements, metadata, _config) do
    Logger.debug("[RLM] LLM request completed",
      span_id: metadata.span_id,
      duration_ms: measurements.duration_ms,
      total_tokens: measurements.total_tokens
    )
  end

  def handle_event([:rlm, :llm, :request, :exception], measurements, metadata, _config) do
    Logger.error("[RLM] LLM request failed",
      span_id: metadata.span_id,
      duration_ms: measurements.duration_ms,
      error: metadata.error
    )
  end

  def handle_event([:rlm, :subcall, :spawn], _measurements, metadata, _config) do
    Logger.debug("[RLM] Spawned subcall",
      parent_span_id: metadata.span_id,
      child_span_id: metadata[:child_span_id],
      child_depth: metadata[:child_depth]
    )
  end

  def handle_event([:rlm, :direct_query, :start], _measurements, metadata, _config) do
    Logger.debug("[RLM] Direct query started",
      span_id: metadata.span_id,
      query_id: metadata[:query_id],
      model_size: metadata[:model_size]
    )
  end

  def handle_event([:rlm, :direct_query, :stop], _measurements, metadata, _config) do
    Logger.debug("[RLM] Direct query completed",
      span_id: metadata.span_id,
      query_id: metadata[:query_id],
      status: metadata[:status]
    )
  end

  def handle_event([:rlm, :turn, :complete], measurements, metadata, _config) do
    Logger.info("[RLM] Turn completed",
      span_id: metadata.span_id,
      status: metadata.status,
      duration_ms: measurements.duration_ms,
      total_iterations: measurements.total_iterations
    )
  end

  def handle_event(_event, _measurements, _metadata, _config) do
    :ok
  end
end
