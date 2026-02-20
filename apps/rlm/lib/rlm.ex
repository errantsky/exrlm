defmodule RLM do
  @moduledoc """
  Public API for the Recursive Language Model engine.

  ## Usage

      # Single-turn query
      {:ok, answer, run_id} = RLM.run("Your long input text...", "Summarize this")

      # With config overrides
      {:ok, answer, run_id} = RLM.run(context, query, model_large: "claude-opus-4-6")

      # Async execution
      {:ok, run_id, pid} = RLM.run_async(context, query)

      # Multi-turn (keep_alive mode)
      {:ok, answer, span_id} = RLM.run(context, query, keep_alive: true)
      {:ok, follow_up} = RLM.send_message(span_id, "Now do something else with it")
  """

  @spec run(String.t(), String.t(), keyword()) :: {:ok, any(), String.t()} | {:error, any()}
  def run(context, query, opts \\ []) do
    config = RLM.Config.load(opts)
    span_id = RLM.Span.generate_id()
    run_id = RLM.Span.generate_run_id()
    # Generous overall timeout: two full eval cycles worth
    total_timeout = config.eval_timeout * 2

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
      {:ok, pid} ->
        ref = Process.monitor(pid)

        receive do
          {:rlm_result, ^span_id, {:ok, answer}} ->
            Process.demonitor(ref, [:flush])
            {:ok, answer, span_id}

          {:rlm_result, ^span_id, {:error, reason}} ->
            Process.demonitor(ref, [:flush])
            {:error, reason}

          {:DOWN, ^ref, :process, ^pid, :normal} ->
            {:error, "Worker exited normally without sending a result"}

          {:DOWN, ^ref, :process, ^pid, reason} ->
            {:error, "Worker crashed: #{inspect(reason)}"}
        after
          total_timeout ->
            Process.demonitor(ref, [:flush])
            DynamicSupervisor.terminate_child(RLM.WorkerSup, pid)
            {:error, "RLM.run timed out after #{total_timeout}ms"}
        end

      {:error, reason} ->
        {:error, "Failed to start worker: #{inspect(reason)}"}
    end
  end

  @doc """
  Send a follow-up message to a keep-alive Worker identified by `span_id`.
  The Worker must have been started with `keep_alive: true` and be in `:idle` status.
  """
  @spec send_message(String.t(), String.t(), non_neg_integer()) ::
          {:ok, any()} | {:error, any()}
  def send_message(span_id, text, timeout \\ 120_000) do
    GenServer.call(via(span_id), {:send_message, text}, timeout)
  end

  @doc "Return the full message history for a Worker."
  @spec history(String.t()) :: [map()]
  def history(span_id) do
    GenServer.call(via(span_id), :history)
  end

  @doc "Return status and statistics for a Worker."
  @spec status(String.t()) :: map()
  def status(span_id) do
    GenServer.call(via(span_id), :status)
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

  defp via(span_id) do
    {:via, Registry, {RLM.Registry, {:worker, span_id}}}
  end
end
