defmodule RLM.Agent.Session do
  @moduledoc """
  GenServer that manages a single coding agent session.

  Implements the tool-use loop:
    1. Send messages + tools to LLM
    2. If LLM returns tool_calls → execute each tool, append results, go to 1
    3. If LLM returns text → the turn is complete

  ## State machine

      :idle      — waiting for a message from the user
      :running   — a turn is in progress (LLM call or tool execution)
      :complete  — session has been explicitly finalised (not used yet)

  ## PubSub events

  Every significant event is broadcast on `"agent:session:<session_id>"`:

      {:agent_event, :turn_start, %{session_id: id, turn: n}}
      {:agent_event, :text_chunk, %{session_id: id, text: chunk}}   # streaming
      {:agent_event, :tool_call_start, %{session_id: id, call: call}}
      {:agent_event, :tool_call_end, %{session_id: id, call: call, result: result}}
      {:agent_event, :turn_complete, %{session_id: id, response: text, turn: n}}
      {:agent_event, :error, %{session_id: id, reason: reason}}
  """

  use GenServer, restart: :temporary

  require Logger

  alias RLM.Agent.{LLM, Message, ToolRegistry}

  # How many tool-call rounds to allow before aborting a turn
  @max_tool_rounds 20

  defstruct [
    :session_id,
    :config,
    :system_prompt,
    :tools,
    :model,
    :stream,
    :status,
    :turn,
    messages: [],
    total_input_tokens: 0,
    total_output_tokens: 0
  ]

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  def start_link(opts) do
    session_id = Keyword.get(opts, :session_id, RLM.Span.generate_run_id())
    GenServer.start_link(__MODULE__, opts, name: via(session_id))
  end

  defp via(session_id) do
    {:via, Registry, {RLM.Registry, {:agent_session, session_id}}}
  end

  @doc "Send a user message to the session and get the final response synchronously."
  def send_message(session_id, text, timeout \\ 120_000) do
    GenServer.call(via(session_id), {:send_message, text}, timeout)
  end

  @doc "Return the full message history."
  def history(session_id) do
    GenServer.call(via(session_id), :history)
  end

  @doc "Return current session status and statistics."
  def status(session_id) do
    GenServer.call(via(session_id), :status)
  end

  # ---------------------------------------------------------------------------
  # GenServer callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def init(opts) do
    session_id = Keyword.get(opts, :session_id, RLM.Span.generate_run_id())
    config = Keyword.get(opts, :config, RLM.Config.load())
    system_prompt = Keyword.get(opts, :system_prompt, RLM.Agent.Prompt.build())
    tools = Keyword.get(opts, :tools, ToolRegistry.specs())
    model = Keyword.get(opts, :model, config.model_large)
    stream = Keyword.get(opts, :stream, false)

    state = %__MODULE__{
      session_id: session_id,
      config: config,
      system_prompt: system_prompt,
      tools: tools,
      model: model,
      stream: stream,
      status: :idle,
      turn: 0,
      messages: []
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:send_message, _text}, _from, %{status: :running} = state) do
    {:reply, {:error, "Session is busy — a turn is already in progress"}, state}
  end

  def handle_call({:send_message, text}, from, state) do
    new_messages = state.messages ++ [Message.user(text)]
    state = %{state | messages: new_messages, status: :running}
    parent = self()

    Task.Supervisor.start_child(RLM.TaskSupervisor, fn ->
      result = run_turn(state, @max_tool_rounds)
      send(parent, {:turn_done, from, result})
    end)

    {:noreply, state}
  end

  def handle_call(:history, _from, state) do
    {:reply, state.messages, state}
  end

  def handle_call(:status, _from, state) do
    info = %{
      session_id: state.session_id,
      status: state.status,
      turn: state.turn,
      message_count: length(state.messages),
      total_input_tokens: state.total_input_tokens,
      total_output_tokens: state.total_output_tokens
    }

    {:reply, info, state}
  end

  @impl true
  def handle_info({:turn_done, from, {:ok, response_text, new_messages, usage}}, state) do
    state = %{
      state
      | messages: new_messages,
        status: :idle,
        turn: state.turn + 1,
        total_input_tokens: state.total_input_tokens + usage.input_tokens,
        total_output_tokens: state.total_output_tokens + usage.output_tokens
    }

    broadcast(state, :turn_complete, %{response: response_text, turn: state.turn - 1})
    GenServer.reply(from, {:ok, response_text})
    {:noreply, state}
  end

  def handle_info({:turn_done, from, {:error, reason}}, state) do
    state = %{state | status: :idle}
    broadcast(state, :error, %{reason: reason})
    GenServer.reply(from, {:error, reason})
    {:noreply, state}
  end

  # ---------------------------------------------------------------------------
  # Turn execution (runs inside Task.Supervisor child)
  # ---------------------------------------------------------------------------

  defp run_turn(state, rounds_left) do
    broadcast(state, :turn_start, %{turn: state.turn})

    on_chunk =
      if state.stream do
        fn chunk ->
          broadcast(state, :text_chunk, %{text: chunk})
        end
      end

    llm_opts = [
      tools: state.tools,
      system: state.system_prompt,
      stream: state.stream,
      on_chunk: on_chunk
    ]

    case LLM.call(state.messages, state.model, state.config, llm_opts) do
      {:ok, {:text, text}, usage} ->
        assistant_msg = Message.assistant(text)
        {:ok, text, state.messages ++ [assistant_msg], usage}

      {:ok, {:tool_calls, calls, text}, usage} ->
        handle_tool_calls(state, calls, text, usage, rounds_left - 1)

      {:error, reason} ->
        {:error, "LLM call failed: #{reason}"}
    end
  end

  defp handle_tool_calls(_state, _calls, _text, _usage, 0) do
    {:error, "Too many tool-call rounds — possible loop detected"}
  end

  defp handle_tool_calls(state, calls, thinking_text, usage, rounds_left) do
    # Build the assistant message with the tool_use content blocks
    blocks =
      []
      |> maybe_prepend_text(thinking_text)
      |> Enum.concat(
        Enum.map(calls, fn %{id: id, name: name, input: input} ->
          %{"type" => "tool_use", "id" => id, "name" => name, "input" => input}
        end)
      )

    assistant_msg = Message.assistant_from_blocks(blocks)

    # Execute each tool
    results =
      Enum.map(calls, fn call ->
        broadcast(state, :tool_call_start, %{call: call})

        result = ToolRegistry.execute(call.name, call.input)

        broadcast(state, :tool_call_end, %{call: call, result: result})

        case result do
          {:ok, output} -> %{tool_use_id: call.id, content: output}
          {:error, reason} -> %{tool_use_id: call.id, content: reason, is_error: true}
        end
      end)

    result_msg = Message.tool_results(results)
    new_messages = state.messages ++ [assistant_msg, result_msg]

    # Continue the turn with the tool results
    accumulated_usage = %{
      input_tokens: usage.input_tokens,
      output_tokens: usage.output_tokens
    }

    next_state = %{state | messages: new_messages}

    case run_turn(next_state, rounds_left) do
      {:ok, text, final_messages, next_usage} ->
        merged_usage = %{
          input_tokens: accumulated_usage.input_tokens + next_usage.input_tokens,
          output_tokens: accumulated_usage.output_tokens + next_usage.output_tokens
        }

        {:ok, text, final_messages, merged_usage}

      error ->
        error
    end
  end

  defp maybe_prepend_text(blocks, nil), do: blocks
  defp maybe_prepend_text(blocks, ""), do: blocks
  defp maybe_prepend_text(blocks, text), do: [%{"type" => "text", "text" => text} | blocks]

  # ---------------------------------------------------------------------------
  # PubSub helpers
  # ---------------------------------------------------------------------------

  defp broadcast(state, event_type, extra) do
    payload = Map.merge(%{session_id: state.session_id}, extra)

    Phoenix.PubSub.broadcast(
      RLM.PubSub,
      "agent:session:#{state.session_id}",
      {:agent_event, event_type, payload}
    )
  end
end
