defmodule RLM do
  @moduledoc """
  Public API for the Recursive Language Model engine.

  ## One-shot queries

      {:ok, answer, run_id} = RLM.run("Your long input text...", "Summarize this")

  ## Interactive sessions

      {:ok, session_id} = RLM.start_session(cwd: ".")
      {:ok, answer} = RLM.send_message(session_id, "List files in current directory")
      {:ok, answer2} = RLM.send_message(session_id, "Now read the README")
      history = RLM.history(session_id)
  """

  # ---------------------------------------------------------------------------
  # One-shot API
  # ---------------------------------------------------------------------------

  @spec run(String.t(), String.t(), keyword()) :: {:ok, any(), String.t()} | {:error, any()}
  def run(context, query, opts \\ []) when is_binary(context) and is_binary(query) do
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
            {:ok, answer, run_id}

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

  # ---------------------------------------------------------------------------
  # Interactive Session API
  # ---------------------------------------------------------------------------

  @doc """
  Start an interactive keep-alive session.

  The Worker starts idle and waits for `send_message/3` calls.
  Bindings persist across turns.

  Options:
    - `:cwd` — working directory for tools (default: current dir)
    - `:model` — override the model (default: config.model_large)
    - Plus any `RLM.Config` overrides

  Returns `{:ok, session_id}`.
  """
  @spec start_session(keyword()) :: {:ok, String.t()} | {:error, any()}
  def start_session(opts \\ []) do
    config = RLM.Config.load(opts)
    session_id = RLM.Span.generate_id()
    run_id = RLM.Span.generate_run_id()
    cwd = Keyword.get(opts, :cwd, File.cwd!())
    model = Keyword.get(opts, :model, config.model_large)

    worker_opts = [
      span_id: session_id,
      run_id: run_id,
      config: config,
      keep_alive: true,
      cwd: cwd,
      model: model
    ]

    case DynamicSupervisor.start_child(RLM.WorkerSup, {RLM.Worker, worker_opts}) do
      {:ok, _pid} -> {:ok, session_id}
      {:error, reason} -> {:error, "Failed to start session: #{inspect(reason)}"}
    end
  end

  @doc """
  Send a message to a keep-alive session and wait for the response.

  Returns `{:ok, answer}` or `{:error, reason}`.
  """
  @spec send_message(String.t(), String.t(), non_neg_integer()) ::
          {:ok, any()} | {:error, any()}
  def send_message(session_id, text, timeout \\ 120_000) do
    GenServer.call(via(session_id), {:send_message, text}, timeout)
  end

  @doc "Get the full message history for a session."
  @spec history(String.t()) :: [map()]
  def history(session_id) do
    GenServer.call(via(session_id), :history)
  end

  @doc "Get the status of a session."
  @spec status(String.t()) :: map()
  def status(session_id) do
    GenServer.call(via(session_id), :status)
  end

  defp via(session_id) do
    {:via, Registry, {RLM.Registry, {:worker, session_id}}}
  end
end
