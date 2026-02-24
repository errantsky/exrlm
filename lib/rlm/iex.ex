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
    {:ok, info} = RLM.status(session_id)
    topic = "rlm:run:#{info.run_id}"
    Phoenix.PubSub.subscribe(RLM.PubSub, topic)
    IO.puts("Watching session #{session_id} (run: #{info.run_id})...\n")

    try do
      watch_loop(timeout)
    after
      Phoenix.PubSub.unsubscribe(RLM.PubSub, topic)
    end
  end

  @doc "Print the full message history for a session."
  @spec history(String.t()) :: :ok | {:error, :not_found}
  def history(session_id) do
    case RLM.history(session_id) do
      {:ok, messages} ->
        Enum.each(messages, &print_message/1)

      {:error, :not_found} ->
        IO.puts("[Error] Session #{session_id} not found")
        {:error, :not_found}
    end
  end

  @doc "Print session statistics."
  @spec status(String.t()) :: map() | {:error, :not_found}
  def status(session_id) do
    case RLM.status(session_id) do
      {:ok, info} ->
        IO.puts("""
        Session: #{info.session_id}
        Run ID:  #{info.run_id}
        Status:  #{info.status}
        Messages:#{info.message_count}
        CWD:     #{info.cwd}
        """)

        info

      {:error, :not_found} ->
        IO.puts("[Error] Session #{session_id} not found")
        {:error, :not_found}
    end
  end

  @doc """
  Run an RLM one-shot query on a remote node and print the result.

  Requires distribution to be started (via `RLM.Node.start/1` or
  `--sname`/`--name` flag) with a shared cookie.

  Returns `{:ok, answer, run_id}` on success or `{:error, reason}` on failure.

  ## Options

    * `:context` — input data (default: `""`)
    * `:timeout` — RPC timeout in ms (default: `120_000`)
  """
  @spec remote(node(), String.t(), keyword()) :: {:ok, any(), String.t()} | {:error, any()}
  def remote(node, message, opts \\ []) do
    unless Node.alive?() do
      IO.puts("[Error] Distribution not started. Run RLM.Node.start() first.")
      {:error, :not_distributed}
    else
      context = Keyword.get(opts, :context, "")
      timeout = Keyword.get(opts, :timeout, 120_000)

      IO.puts("[Remote #{node}] #{message}\n")

      case RLM.Node.rpc(node, RLM, :run, [context, message], timeout) do
        {:ok, {:ok, answer, run_id}} ->
          IO.puts("[RLM] run=#{run_id}\n#{inspect(answer)}\n")
          {:ok, answer, run_id}

        {:ok, {:error, reason}} ->
          IO.puts("[Error] #{inspect(reason)}")
          {:error, reason}

        {:ok, other} ->
          IO.puts("[Unexpected response] #{inspect(other)}")
          {:error, {:unexpected_response, other}}

        {:error, {:rpc_failed, _} = err} ->
          IO.puts("[RPC Error] #{inspect(err)}")
          {:error, err}
      end
    end
  end

  @doc """
  Print current node distribution info. Cookie is redacted in output.
  """
  @spec node_info() :: :ok
  def node_info do
    %RLM.Node.Info{} = info = RLM.Node.info()

    IO.puts("""
    Node:       #{info.node}
    Alive:      #{info.alive}
    Cookie:     #{redact_cookie(info.cookie)}
    Connected:  #{inspect(info.connected_nodes)}
    """)

    :ok
  end

  defp redact_cookie(cookie) do
    str = Atom.to_string(cookie)

    if String.length(str) > 4 do
      String.slice(str, 0, 4) <> "****"
    else
      "****"
    end
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
