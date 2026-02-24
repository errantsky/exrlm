defmodule RLM.Telemetry.EventLogHandler do
  @moduledoc """
  Telemetry handler that writes events to the per-run EventLog agent.
  """

  def handle_event([:rlm, :node, :start], _measurements, metadata, _config) do
    ensure_event_log(metadata.run_id)

    event = %{
      type: :node_start,
      span_id: metadata.span_id,
      parent_span_id: metadata.parent_span_id,
      depth: metadata.depth,
      model: metadata.model,
      context_bytes: metadata[:context_bytes],
      timestamp_us: System.system_time(:microsecond)
    }

    RLM.EventLog.append(metadata.run_id, event)
    RLM.TraceStore.put_event(metadata.run_id, event)
  end

  def handle_event([:rlm, :node, :stop], measurements, metadata, _config) do
    event = %{
      type: :node_stop,
      span_id: metadata.span_id,
      depth: metadata.depth,
      status: metadata.status,
      result_preview: metadata[:result_preview],
      duration_ms: measurements.duration_ms,
      total_iterations: measurements.total_iterations,
      timestamp_us: System.system_time(:microsecond)
    }

    RLM.EventLog.append(metadata.run_id, event)
    RLM.TraceStore.put_event(metadata.run_id, event)
  end

  def handle_event([:rlm, :iteration, :stop], measurements, metadata, _config) do
    event = %{
      type: :iteration_stop,
      span_id: metadata.span_id,
      depth: metadata.depth,
      iteration: metadata.iteration,
      duration_ms: measurements.duration_ms,
      code: metadata[:code],
      stdout_preview: metadata[:stdout_preview],
      stdout_bytes: metadata[:stdout_bytes],
      eval_status: metadata[:eval_status],
      eval_duration_ms: metadata[:eval_duration_ms],
      result_preview: metadata[:result_preview],
      final_answer: metadata[:final_answer],
      bindings_snapshot: metadata[:bindings_snapshot],
      subcalls_spawned: metadata[:subcalls_spawned],
      llm_prompt_tokens: metadata[:llm_prompt_tokens],
      llm_completion_tokens: metadata[:llm_completion_tokens],
      cache_creation_input_tokens: metadata[:cache_creation_input_tokens],
      cache_read_input_tokens: metadata[:cache_read_input_tokens],
      llm_duration_ms: metadata[:llm_duration_ms],
      timestamp_us: System.system_time(:microsecond)
    }

    RLM.EventLog.append(metadata.run_id, event)
    RLM.TraceStore.put_event(metadata.run_id, event)
  end

  def handle_event([:rlm, :subcall, :spawn], _measurements, metadata, _config) do
    event = %{
      type: :subcall_spawn,
      span_id: metadata.span_id,
      child_span_id: metadata[:child_span_id],
      child_depth: metadata[:child_depth],
      context_bytes: metadata[:context_bytes],
      model_size: metadata[:model_size],
      timestamp_us: System.system_time(:microsecond)
    }

    RLM.EventLog.append(metadata.run_id, event)
    RLM.TraceStore.put_event(metadata.run_id, event)
  end

  def handle_event([:rlm, :direct_query, :start], _measurements, metadata, _config) do
    event = %{
      type: :direct_query_start,
      span_id: metadata.span_id,
      query_id: metadata[:query_id],
      model_size: metadata[:model_size],
      text_bytes: metadata[:text_bytes],
      timestamp_us: System.system_time(:microsecond)
    }

    RLM.EventLog.append(metadata.run_id, event)
    RLM.TraceStore.put_event(metadata.run_id, event)
  end

  def handle_event([:rlm, :direct_query, :stop], _measurements, metadata, _config) do
    event = %{
      type: :direct_query_stop,
      span_id: metadata.span_id,
      query_id: metadata[:query_id],
      status: metadata[:status],
      result_preview: metadata[:result_preview],
      timestamp_us: System.system_time(:microsecond)
    }

    RLM.EventLog.append(metadata.run_id, event)
    RLM.TraceStore.put_event(metadata.run_id, event)
  end

  def handle_event([:rlm, :subcall, :result], measurements, metadata, _config) do
    event = %{
      type: :subcall_result,
      span_id: metadata.span_id,
      child_span_id: metadata[:child_span_id],
      status: metadata[:status],
      result_preview: metadata[:result_preview],
      duration_ms: measurements[:duration_ms],
      timestamp_us: System.system_time(:microsecond)
    }

    RLM.EventLog.append(metadata.run_id, event)
    RLM.TraceStore.put_event(metadata.run_id, event)
  end

  def handle_event([:rlm, :turn, :complete], measurements, metadata, _config) do
    event = %{
      type: :turn_complete,
      span_id: metadata.span_id,
      depth: metadata.depth,
      status: metadata.status,
      result_preview: metadata[:result_preview],
      duration_ms: measurements.duration_ms,
      total_iterations: measurements.total_iterations,
      timestamp_us: System.system_time(:microsecond)
    }

    RLM.EventLog.append(metadata.run_id, event)
    RLM.TraceStore.put_event(metadata.run_id, event)
  end

  def handle_event(_event, _measurements, _metadata, _config) do
    :ok
  end

  defp ensure_event_log(run_id) do
    case Registry.lookup(RLM.Registry, {:event_log, run_id}) do
      [{_pid, _}] ->
        :ok

      [] ->
        DynamicSupervisor.start_child(RLM.EventStore, {RLM.EventLog, run_id})
        :ok
    end
  rescue
    _ -> :ok
  end
end
