defmodule RLM.IEx do
  @moduledoc """
  Convenience helpers for interactive RLM sessions from IEx.

  ## Quick start

      iex> session = RLM.IEx.start()
      "span-abc123"

      iex> RLM.IEx.chat(session, "List files in the current directory")
      # => prints response to stdout

      iex> RLM.IEx.watch(session)
      # => subscribes to live telemetry events

      iex> RLM.IEx.history(session)
      # => prints full message history

  ## Shortcuts

      iex> import RLM.IEx
      iex> {session, _} = start_chat("Count the lines in README.md")
  """

  @doc """
  Start a new interactive session. Returns the `session_id`.

  Options:
    - `:model` — override the model (default: config.model_large)
    - `:cwd`   — working directory for tools (default: current dir)
  """
  @spec start(keyword()) :: String.t()
  def start(opts \\ []) do
    case RLM.start_session(opts) do
      {:ok, session_id} ->
        IO.puts("Session started: #{session_id}")
        session_id

      {:error, reason} ->
        IO.puts("[Error] #{inspect(reason)}")
        raise "Failed to start session: #{inspect(reason)}"
    end
  end

  @doc """
  Send a message to the session and print the response.
  Returns `{session_id, response}`.
  """
  @spec chat(String.t(), String.t(), keyword()) :: {String.t(), any()} | {:error, any()}
  def chat(session_id, message, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 120_000)
    IO.puts("\n[You] #{message}\n")

    case RLM.send_message(session_id, message, timeout) do
      {:ok, response} ->
        IO.puts("[RLM]\n#{inspect(response)}\n")
        {session_id, response}

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
    session_id = start(opts)
    chat(session_id, message, opts)
  end

  @doc """
  Subscribe to telemetry events for a session and print them to stdout.
  Returns after the next `:turn_complete` or `:node_stop` event, or after timeout.
  """
  @spec watch(String.t(), non_neg_integer()) :: :ok
  def watch(session_id, timeout \\ 60_000) do
    status = RLM.status(session_id)
    topic = "rlm:run:#{status.run_id}"
    Phoenix.PubSub.subscribe(RLM.PubSub, topic)
    IO.puts("Watching session #{session_id} (run: #{status.run_id})...\n")
    watch_loop(timeout)
  after
    status = RLM.status(session_id)
    Phoenix.PubSub.unsubscribe(RLM.PubSub, "rlm:run:#{status.run_id}")
  end

  @doc "Print the full message history for a session."
  @spec history(String.t()) :: :ok
  def history(session_id) do
    session_id
    |> RLM.history()
    |> Enum.each(&print_message/1)
  end

  @doc "Print session statistics."
  @spec status(String.t()) :: map()
  def status(session_id) do
    info = RLM.status(session_id)

    IO.puts("""
    Session: #{info.session_id}
    Run ID:  #{info.run_id}
    Status:  #{info.status}
    Messages:#{info.message_count}
    CWD:     #{info.cwd}
    """)

    info
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp watch_loop(timeout) do
    receive do
      %{event: [:rlm, :iteration, :stop], metadata: meta} ->
        code = meta[:code] || "(no code)"
        status = meta[:eval_status]
        IO.puts("[Iter #{meta.iteration}] #{status} — #{String.slice(code, 0, 120)}")
        watch_loop(timeout)

      %{event: [:rlm, :turn, :complete], metadata: meta} ->
        IO.puts("\n[Turn complete] #{meta.status}")
        :ok

      %{event: [:rlm, :node, :stop], metadata: meta} ->
        IO.puts("\n[Done] #{meta.status}")
        :ok

      %{event: [:rlm, :llm, :request, :exception], metadata: meta} ->
        IO.puts("\n[LLM Error] #{meta[:error]}")
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
