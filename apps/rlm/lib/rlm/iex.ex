defmodule RLM.IEx do
  @moduledoc """
  Convenience helpers for interacting with the RLM engine from IEx.

  ## Quick start

      iex> import RLM.IEx
      iex> {id, _answer} = start_chat("What files are in the current directory?")
      iex> chat(id, "Now count the .ex files")
      iex> history(id)
      iex> status(id)
  """

  @doc """
  Start a new keep-alive Worker session. Returns the `span_id`.

  Options are passed to `RLM.Config.load/1`:
    - `:model_large`  — override the model
    - `:cwd`          — working directory (default: current dir)
  """
  @spec start(keyword()) :: String.t()
  def start(opts \\ []) do
    opts = Keyword.put_new(opts, :keep_alive, true)
    config = RLM.Config.load(opts)
    span_id = RLM.Span.generate_id()
    run_id = RLM.Span.generate_run_id()
    cwd = Keyword.get(opts, :cwd, File.cwd!())

    worker_opts = [
      span_id: span_id,
      run_id: run_id,
      context: "",
      query: "You are a coding assistant. Wait for the user's first message.",
      config: config,
      depth: 0,
      model: config.model_large,
      caller: self(),
      cwd: cwd
    ]

    {:ok, _pid} = DynamicSupervisor.start_child(RLM.WorkerSup, {RLM.Worker, worker_opts})

    # Wait for the initial run to complete (the "wait for user" query)
    receive do
      {:rlm_result, ^span_id, _result} -> :ok
    after
      30_000 -> IO.puts("[Timeout] Worker did not initialize")
    end

    IO.puts("Session started: #{span_id}")
    span_id
  end

  @doc """
  Send a message to a keep-alive Worker and print the response.
  Returns `{span_id, response}`.
  """
  @spec chat(String.t(), String.t(), keyword()) :: {String.t(), any()} | {:error, any()}
  def chat(span_id, message, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 120_000)
    IO.puts("\n[You] #{message}\n")

    case RLM.send_message(span_id, message, timeout) do
      {:ok, answer} ->
        IO.puts("[RLM] #{inspect(answer)}\n")
        {span_id, answer}

      {:error, reason} ->
        IO.puts("[Error] #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Start a session and immediately send a first message.
  """
  @spec start_chat(String.t(), keyword()) :: {String.t(), any()} | {:error, any()}
  def start_chat(message, opts \\ []) do
    span_id = start(opts)
    chat(span_id, message, opts)
  end

  @doc """
  Subscribe to all PubSub events for a Worker and print them to stdout.
  Returns after the next `:complete` event or timeout.
  """
  @spec watch(String.t(), non_neg_integer()) :: :ok
  def watch(span_id, timeout \\ 60_000) do
    topic = "rlm:worker:#{span_id}"
    Phoenix.PubSub.subscribe(RLM.PubSub, topic)
    IO.puts("Watching worker #{span_id}...\n")
    watch_loop(timeout)
  after
    Phoenix.PubSub.unsubscribe(RLM.PubSub, "rlm:worker:#{span_id}")
  end

  @doc "Print the full message history for a Worker."
  @spec history(String.t()) :: :ok
  def history(span_id) do
    span_id
    |> RLM.history()
    |> Enum.each(&print_message/1)
  end

  @doc "Print Worker statistics."
  @spec status(String.t()) :: map()
  def status(span_id) do
    info = RLM.status(span_id)

    IO.puts("""
    Worker:     #{info.span_id}
    Status:     #{info.status}
    Iterations: #{info.iteration}
    Messages:   #{info.message_count}
    Depth:      #{info.depth}
    Model:      #{info.model}
    """)

    info
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp watch_loop(timeout) do
    receive do
      {:rlm_event, :iteration_start, %{iteration: n}} ->
        IO.puts("[Iteration #{n}] starting...")
        watch_loop(timeout)

      {:rlm_event, :iteration_stop, %{code: code, final_answer: answer}} ->
        IO.puts("[Code]\n#{code}\n")

        if answer do
          IO.puts("[Final answer] #{inspect(answer)}")
        end

        watch_loop(timeout)

      {:rlm_event, :complete, %{result: result}} ->
        IO.puts("\n[Done] #{inspect(result)}\n")
        :ok

      {:rlm_event, :error, %{reason: reason}} ->
        IO.puts("\n[Error] #{reason}")
        :ok

      _ ->
        watch_loop(timeout)
    after
      timeout ->
        IO.puts("\n[watch timed out]")
        :ok
    end
  end

  defp print_message(%{role: role, content: content}) do
    IO.puts("[#{String.upcase(to_string(role))}]\n#{content}\n")
  end
end
