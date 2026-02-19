defmodule RLM.Agent.IEx do
  @moduledoc """
  Convenience helpers for interacting with the coding agent from IEx.

  ## Quick start

      # Start an interactive session
      iex> session = RLM.Agent.IEx.start()
      "sess-abc123"

      # Send messages
      iex> RLM.Agent.IEx.chat(session, "What files are in the current directory?")
      # => prints response to stdout

      # Subscribe to live events (streaming + tool calls)
      iex> RLM.Agent.IEx.watch(session)

      # Show full message history
      iex> RLM.Agent.IEx.history(session)

  ## Shortcuts

      iex> import RLM.Agent.IEx
      iex> {session, _} = start_chat("Explain the RLM engine architecture")
  """

  alias RLM.Agent.Session

  @doc """
  Start a new agent session. Returns the `session_id`.

  Options are passed directly to `RLM.Agent.Session.start_link/1`:
    - `:model`   — override the model (default: config.model_large)
    - `:stream`  — enable streaming (default: false for IEx, cleaner output)
    - `:cwd`     — working directory for the prompt (default: current dir)
  """
  @spec start(keyword()) :: String.t()
  def start(opts \\ []) do
    session_id = "sess-#{:rand.uniform(999_999)}"
    cwd = Keyword.get(opts, :cwd, File.cwd!())

    config = RLM.Config.load()

    session_opts =
      [
        session_id: session_id,
        config: config,
        system_prompt: RLM.Agent.Prompt.build(cwd: cwd),
        stream: Keyword.get(opts, :stream, false)
      ]
      |> maybe_put(:model, Keyword.get(opts, :model))

    {:ok, _pid} =
      DynamicSupervisor.start_child(
        RLM.AgentSup,
        {Session, session_opts}
      )

    IO.puts("Session started: #{session_id}")
    session_id
  end

  @doc """
  Send a message to the session and print the response.
  Returns `{session_id, response_text}`.
  """
  @spec chat(String.t(), String.t(), keyword()) :: {String.t(), String.t()} | {:error, any()}
  def chat(session_id, message, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 120_000)
    IO.puts("\n[You] #{message}\n")

    case Session.send_message(session_id, message, timeout) do
      {:ok, response} ->
        IO.puts("[Agent]\n#{response}\n")
        {session_id, response}

      {:error, reason} ->
        IO.puts("[Error] #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Start a session and immediately send a first message.
  """
  @spec start_chat(String.t(), keyword()) :: {String.t(), String.t()} | {:error, any()}
  def start_chat(message, opts \\ []) do
    session_id = start(opts)
    chat(session_id, message, opts)
  end

  @doc """
  Subscribe to all events for a session and print them to stdout.
  Returns after the next `:turn_complete` or `:error` event.
  """
  @spec watch(String.t(), non_neg_integer()) :: :ok
  def watch(session_id, timeout \\ 60_000) do
    topic = "agent:session:#{session_id}"
    Phoenix.PubSub.subscribe(RLM.PubSub, topic)
    IO.puts("Watching session #{session_id}...\n")
    watch_loop(timeout)
  after
    Phoenix.PubSub.unsubscribe(RLM.PubSub, "agent:session:#{session_id}")
  end

  @doc "Print the full message history for a session."
  @spec history(String.t()) :: :ok
  def history(session_id) do
    session_id
    |> Session.history()
    |> Enum.each(&print_message/1)
  end

  @doc "Print session statistics."
  @spec status(String.t()) :: map()
  def status(session_id) do
    info = Session.status(session_id)

    IO.puts("""
    Session: #{info.session_id}
    Status:  #{info.status}
    Turn:    #{info.turn}
    Messages:#{info.message_count}
    Tokens:  #{info.total_input_tokens} in / #{info.total_output_tokens} out
    """)

    info
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp watch_loop(timeout) do
    receive do
      {:agent_event, :text_chunk, %{text: chunk}} ->
        IO.write(chunk)
        watch_loop(timeout)

      {:agent_event, :tool_call_start, %{call: %{name: name, input: input}}} ->
        IO.puts("\n[Tool] #{name}(#{Jason.encode!(input)})")
        watch_loop(timeout)

      {:agent_event, :tool_call_end, %{result: {:ok, out}}} ->
        IO.puts("[Tool result] #{String.slice(out, 0, 200)}")
        watch_loop(timeout)

      {:agent_event, :tool_call_end, %{result: {:error, reason}}} ->
        IO.puts("[Tool error] #{reason}")
        watch_loop(timeout)

      {:agent_event, :turn_complete, %{response: text}} ->
        IO.puts("\n[Done]\n#{text}\n")
        :ok

      {:agent_event, :error, %{reason: reason}} ->
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

  defp print_message(%{role: role, content: content}) when is_binary(content) do
    IO.puts("[#{String.upcase(to_string(role))}]\n#{content}\n")
  end

  defp print_message(%{role: role, content: blocks}) when is_list(blocks) do
    IO.puts("[#{String.upcase(to_string(role))}]")

    Enum.each(blocks, fn
      %{"type" => "text", "text" => text} ->
        IO.puts(text)

      %{"type" => "tool_use", "name" => name} ->
        IO.puts("  <tool_use: #{name}>")

      %{"type" => "tool_result", "content" => out} ->
        IO.puts("  <tool_result: #{String.slice(out, 0, 100)}>")

      _ ->
        :ok
    end)

    IO.puts("")
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)
end
