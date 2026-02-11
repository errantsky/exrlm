defmodule RLM do
  @moduledoc """
  Public API for the Recursive Language Model engine.

  ## Usage

      # Single-turn query
      {:ok, answer} = RLM.run("Your long input text...", "Summarize this")

      # With config overrides
      {:ok, answer} = RLM.run(context, query, model_large: "gpt-4o")

      # Async execution
      {:ok, run_id, pid} = RLM.run_async(context, query)
  """

  @spec run(String.t(), String.t(), keyword()) :: {:ok, any()} | {:error, any()}
  def run(context, query, opts \\ []) do
    config = RLM.Config.load(opts)
    span_id = RLM.Span.generate_id()
    run_id = RLM.Span.generate_run_id()

    worker_opts = [
      span_id: span_id,
      run_id: run_id,
      context: context,
      query: query,
      config: config,
      depth: 0,
      model: config.model_large,
      caller: self()
    ]

    case DynamicSupervisor.start_child(RLM.WorkerSup, {RLM.Worker, worker_opts}) do
      {:ok, _pid} ->
        receive do
          {:rlm_result, ^span_id, result} -> result
        end

      {:error, reason} ->
        {:error, "Failed to start worker: #{inspect(reason)}"}
    end
  end

  @spec run_async(String.t(), String.t(), keyword()) :: {:ok, String.t(), pid()}
  def run_async(context, query, opts \\ []) do
    config = RLM.Config.load(opts)
    span_id = RLM.Span.generate_id()
    run_id = RLM.Span.generate_run_id()

    worker_opts = [
      span_id: span_id,
      run_id: run_id,
      context: context,
      query: query,
      config: config,
      depth: 0,
      model: config.model_large,
      caller: self()
    ]

    case DynamicSupervisor.start_child(RLM.WorkerSup, {RLM.Worker, worker_opts}) do
      {:ok, pid} -> {:ok, run_id, pid}
      {:error, reason} -> {:error, reason}
    end
  end
end
