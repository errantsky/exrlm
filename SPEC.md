# SPEC.md — Canonical OTP-Native Coding Agent with RLM

> An Elixir/OTP coding agent inspired by [Pi](https://github.com/badlogic/pi-mono) with recursive language model capabilities from [RLM](https://github.com/alexzhang13/rlm). Designed for elegance, maintainability, and deep observability.

## Design Principles

1. **OTP-native** — Every concurrent concern is a supervised process. No threads, no mutexes, no external orchestration.
2. **Two modes, one codebase** — The coding agent (tool-use) and the RLM engine (eval-loop) share infrastructure but serve different purposes.
3. **Tracing is a first-class citizen** — Every event is recorded, streamable, and visualizable. If it happened, you can see it.
4. **Start simple, extend later** — Claude API only, IEx + LiveView interface, no multi-provider support initially.
5. **The agent is the user's tool** — It should be easy to invoke from IEx, easy to watch in LiveView, easy to understand from traces.

---

## Phase 0: Fix Existing RLM Engine Issues

> Stabilize the foundation before building on it.

### 0.1 Enforce max_concurrent_subcalls

**File:** `apps/rlm/lib/rlm/worker.ex`

In `handle_call({:spawn_subcall, ...})`, before spawning a child:

```elixir
if map_size(state.pending_subcalls) >= state.config.max_concurrent_subcalls do
  {:reply, {:error, "Max concurrent subcalls (#{state.config.max_concurrent_subcalls}) reached"}, state}
else
  # existing spawn logic
end
```

### 0.2 Add timeout/monitor to RLM.run/3

**File:** `apps/rlm/lib/rlm.ex`

Replace bare `receive` with monitored receive:

```elixir
def run(context, query, opts \\ []) do
  # ... existing setup ...
  case DynamicSupervisor.start_child(RLM.WorkerSup, {RLM.Worker, worker_opts}) do
    {:ok, pid} ->
      ref = Process.monitor(pid)
      receive do
        {:rlm_result, ^span_id, result} ->
          Process.demonitor(ref, [:flush])
          result
        {:DOWN, ^ref, :process, ^pid, reason} ->
          {:error, "Worker crashed: #{inspect(reason)}"}
      after
        config.eval_timeout * 2 ->
          {:error, "RLM.run timed out"}
      end
    {:error, reason} ->
      {:error, "Failed to start worker: #{inspect(reason)}"}
  end
end
```

### 0.3 EventLog cleanup

Add a periodic sweep to `RLM.Application` children:

```elixir
# New module: RLM.EventLog.Sweeper (GenServer)
# Periodically checks EventStore children, terminates those older than TTL (default 1 hour)
```

### 0.4 Return run_id from RLM.run/3

Change return to `{:ok, answer, run_id}` so callers can retrieve traces after sync execution.

### 0.5 Cost tracking

Accumulate token costs in Worker state. Emit `[:rlm, :cost, :update]` telemetry. Propagate child costs to parent via `:rlm_result` message.

---

## Phase 1: LLM Client — Tool Use & Streaming

> Extend `RLM.LLM` to support the Anthropic tool_use API and SSE streaming.

### 1.1 New module: Agent.LLM

**File:** `apps/rlm/lib/agent/llm.ex`

```elixir
defmodule Agent.LLM do
  @moduledoc """
  Anthropic Messages API client with tool_use and streaming support.
  Extends the base RLM.LLM for coding agent needs.
  """

  @doc """
  Send a chat request with tool definitions.
  Returns {:ok, response} where response contains content blocks
  (text and/or tool_use).
  """
  @spec chat(messages :: [map()], tools :: [map()], model :: String.t(), config :: RLM.Config.t()) ::
          {:ok, map()} | {:error, String.t()}

  @doc """
  Stream a chat request. Sends SSE events to the caller process.
  Messages: {:llm_event, event_type, data}
  """
  @spec stream(messages :: [map()], tools :: [map()], model :: String.t(), config :: RLM.Config.t(), pid()) ::
          :ok | {:error, String.t()}
end
```

Key implementation details:
- Include `tools` array in API request body (Anthropic tool_use format)
- Parse response content blocks: `text`, `tool_use` (with id, name, input)
- For streaming: use `stream: true` in request, parse SSE events, forward to caller pid
- Extract `stop_reason`: `"end_turn"` vs `"tool_use"` to know if tools need execution
- Handle `tool_result` messages in the conversation (role: "user", content: [{type: "tool_result", ...}])

### 1.2 Message format helpers

**File:** `apps/rlm/lib/agent/message.ex`

```elixir
defmodule Agent.Message do
  @moduledoc "Message construction helpers for the Anthropic Messages API with tool_use."

  def user(text), do: %{role: "user", content: text}
  def assistant(content_blocks), do: %{role: "assistant", content: content_blocks}
  def tool_result(tool_use_id, content, is_error \\ false)
  def system(text), do: text  # system is top-level in Anthropic API
end
```

---

## Phase 2: Tool System

> A behaviour-based tool registry with implementations for file operations and shell access.

### 2.1 Tool behaviour

**File:** `apps/rlm/lib/agent/tool.ex`

```elixir
defmodule Agent.Tool do
  @moduledoc """
  Behaviour for agent tools. Each tool defines its schema (for the LLM)
  and an execute function.
  """

  @type tool_result :: {:ok, String.t()} | {:ok, String.t(), map()} | {:error, String.t()}

  @doc "Tool name as used in tool_use API"
  @callback name() :: String.t()

  @doc "Human-readable description for the LLM"
  @callback description() :: String.t()

  @doc "JSON Schema for parameters (Anthropic input_schema format)"
  @callback input_schema() :: map()

  @doc "Execute the tool with validated parameters. Returns text result."
  @callback execute(params :: map(), context :: map()) :: tool_result()

  @doc "Return the Anthropic tool definition map"
  def to_api_spec(module) do
    %{
      name: module.name(),
      description: module.description(),
      input_schema: module.input_schema()
    }
  end
end
```

### 2.2 Tool implementations

Each tool is a module implementing `Agent.Tool`:

#### Tool.Read
**File:** `apps/rlm/lib/agent/tools/read.ex`

- Params: `file_path` (required), `offset` (optional line number), `limit` (optional line count)
- Reads file, returns content with line numbers (cat -n style)
- Truncates output if file is very large (configurable limit)
- Returns error message if file doesn't exist

#### Tool.Write
**File:** `apps/rlm/lib/agent/tools/write.ex`

- Params: `file_path` (required), `content` (required)
- Creates parent directories if needed
- Writes content to file
- Returns confirmation with byte count

#### Tool.Edit
**File:** `apps/rlm/lib/agent/tools/edit.ex`

- Params: `file_path`, `old_string`, `new_string`, `replace_all` (optional, default false)
- Exact string replacement (like Pi/Claude Code)
- Fails if `old_string` is not found or is not unique (unless replace_all)
- Returns diff preview of changes

#### Tool.Bash
**File:** `apps/rlm/lib/agent/tools/bash.ex`

- Params: `command` (required), `timeout` (optional, default 120_000ms)
- Uses `System.cmd/3` or `Port` for execution
- Captures stdout + stderr
- Enforces timeout, kills process if exceeded
- Truncates output (head+tail strategy)

#### Tool.Grep
**File:** `apps/rlm/lib/agent/tools/grep.ex`

- Params: `pattern` (regex), `path` (directory or file), `include` (optional glob filter)
- Shells out to `rg` (ripgrep) if available, falls back to Elixir-native
- Returns matching lines with file:line format
- Truncates long results

#### Tool.Glob
**File:** `apps/rlm/lib/agent/tools/glob.ex`

- Params: `pattern` (glob pattern), `path` (optional base directory)
- Uses `Path.wildcard/2`
- Returns sorted list of matching file paths

#### Tool.Ls
**File:** `apps/rlm/lib/agent/tools/ls.ex`

- Params: `path` (directory)
- Lists directory contents with types (file/dir) and sizes
- Handles nested display for shallow trees

#### Tool.RLM (the bridge)
**File:** `apps/rlm/lib/agent/tools/rlm.ex`

- Params: `context` (text), `query` (task), `model_size` (optional: "small" | "large")
- Invokes `RLM.run/3` with the given context and query
- Returns the RLM result
- This is how the coding agent can leverage recursive processing

### 2.3 Tool registry

**File:** `apps/rlm/lib/agent/tool_registry.ex`

```elixir
defmodule Agent.ToolRegistry do
  @default_tools [
    Agent.Tools.Read,
    Agent.Tools.Write,
    Agent.Tools.Edit,
    Agent.Tools.Bash,
    Agent.Tools.Grep,
    Agent.Tools.Glob,
    Agent.Tools.Ls
  ]

  def default_tools, do: @default_tools
  def all_tools, do: @default_tools ++ [Agent.Tools.RLM]

  def to_api_specs(tools) do
    Enum.map(tools, &Agent.Tool.to_api_spec/1)
  end

  def find_tool(name, tools) do
    Enum.find(tools, fn mod -> mod.name() == name end)
  end
end
```

---

## Phase 3: Agent Session (Core Loop)

> The GenServer that manages a coding agent conversation.

### 3.1 Agent.Session

**File:** `apps/rlm/lib/agent/session.ex`

```elixir
defmodule Agent.Session do
  @moduledoc """
  GenServer managing a single agent conversation.
  Implements the tool-use loop: prompt -> LLM -> tools -> repeat.
  """
  use GenServer, restart: :temporary

  defstruct [
    :session_id,
    :run_id,
    :config,
    :model,
    :tools,
    :system_prompt,
    :messages,        # full conversation history
    :status,          # :idle | :thinking | :executing_tool | :streaming
    :current_turn,    # turn counter
    :cost,            # accumulated cost
    :started_at,
    :caller           # pid to send results to
  ]
end
```

#### Session lifecycle

```
1. Agent.Session.start_link(opts)
   ├── Build system prompt (project context, tool descriptions)
   ├── Register via {:via, Registry, {RLM.Registry, {:session, session_id}}}
   └── Status: :idle

2. handle_call({:prompt, text}, from, state)
   ├── Add user message to history
   ├── Emit [:agent, :turn, :start]
   └── Enter turn loop (async, reply later)

3. Turn loop (runs in spawned process or via send/self)
   ├── Stream LLM response (with tools)
   │   ├── Emit [:agent, :message, :delta] for each chunk
   │   └── Collect full response
   ├── If stop_reason == "end_turn":
   │   ├── Emit [:agent, :turn, :stop]
   │   └── Reply to caller with assistant text
   ├── If stop_reason == "tool_use":
   │   ├── Execute each tool call:
   │   │   ├── Emit [:agent, :tool, :start]
   │   │   ├── Run tool under Task.Supervisor
   │   │   ├── Emit [:agent, :tool, :stop]
   │   │   └── Build tool_result message
   │   ├── Add assistant + tool_results to history
   │   └── Continue turn loop (call LLM again)
   └── If error: reply with error, emit stop event

4. handle_call(:status, _from, state)
   └── Return current state summary

5. handle_call(:history, _from, state)
   └── Return full message history
```

#### Key design decisions

- **Streaming via PubSub**: As tokens arrive, broadcast on `"agent:session:#{session_id}"`. LiveView subscribes to this topic. No direct process coupling.
- **Tool execution under TaskSupervisor**: Each tool runs as a supervised Task. If it crashes, the session catches the error and reports it to the LLM.
- **Turn loop is async**: The Session GenServer spawns the turn processing (similar to RLM Worker's async eval pattern) so it can handle status queries and cancellation requests during execution.
- **History is mutable state**: Messages accumulate in the GenServer state. Compaction runs when approaching context limits.

### 3.2 Context compaction

Two strategies, configurable:

1. **Sliding window** (default): Keep system prompt + last N turns. Drop older turns.
2. **LLM summarization** (optional): Ask a small model to summarize dropped turns into a "previously..." message.

### 3.3 Permission model

For the initial version, keep it simple:

```elixir
defmodule Agent.Permission do
  # Returns :allow | :deny | :ask
  def check(tool_name, params, config) do
    case tool_name do
      "read" -> :allow
      "grep" -> :allow
      "glob" -> :allow
      "ls" -> :allow
      "write" -> if config.auto_approve_writes, do: :allow, else: :ask
      "edit" -> if config.auto_approve_writes, do: :allow, else: :ask
      "bash" -> :ask
      "rlm" -> :allow
      _ -> :deny
    end
  end
end
```

When `:ask` is returned, the session emits a `[:agent, :tool, :permission, :requested]` event and waits for approval via `handle_call({:approve_tool, tool_call_id, :allow | :deny})`.

---

## Phase 4: System Prompt

> Composable system prompt for the coding agent.

**File:** `apps/rlm/lib/agent/prompt.ex`

The system prompt is assembled from parts:

```elixir
defmodule Agent.Prompt do
  def build(opts \\ []) do
    [
      core_identity(),
      tool_guidelines(),
      project_context(opts[:project_root]),
      coding_conventions(),
      if(opts[:enable_rlm], do: rlm_instructions(), else: nil)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n\n")
  end
end
```

**Core identity** — You are a coding agent running in an Elixir/OTP environment. You help with software engineering tasks.

**Tool guidelines** — Prefer read before edit. Use grep/glob to find files. Don't create unnecessary files. Be careful with bash commands.

**Project context** — Auto-detected from the working directory: read CLAUDE.md if present, detect mix.exs/package.json/Cargo.toml for project type, include recent git log.

**RLM instructions** — When you encounter a task that requires processing large amounts of text (logs, data files, many files), use the `rlm` tool to delegate to a recursive language model that can chunk, process, and synthesize the data.

---

## Phase 5: Interface Layer

### 5.1 IEx helpers

**File:** `apps/rlm/lib/agent/iex.ex`

```elixir
defmodule Agent.IEx do
  @moduledoc """
  Convenience functions for interacting with the agent from IEx.

  ## Usage

      iex> Agent.IEx.chat("fix the failing tests")
      # streams response, executes tools, returns final answer

      iex> Agent.IEx.status()
      # shows current session state

      iex> Agent.IEx.history()
      # shows conversation history

      iex> Agent.IEx.new_session()
      # starts a fresh session

      iex> Agent.IEx.sessions()
      # lists all active sessions
  """

  def chat(text, opts \\ []) do
    session = ensure_session(opts)
    # Subscribe to PubSub for streaming output
    Phoenix.PubSub.subscribe(RLM.PubSub, "agent:session:#{session.id}")
    GenServer.call(session.pid, {:prompt, text}, :infinity)
    # Print streamed tokens as they arrive (handled in a receive loop)
  end

  def status, do: ...
  def history, do: ...
  def new_session(opts \\ []), do: ...
  def sessions, do: ...
  def approve(tool_call_id), do: ...
  def deny(tool_call_id), do: ...
end
```

### 5.2 LiveView dashboard

**New umbrella app:** `apps/agent_web/`

A minimal Phoenix LiveView application:

#### Pages

1. **Sessions list** (`/`) — Active sessions, their status, cost, turn count
2. **Session view** (`/sessions/:id`) — Live streaming conversation view
   - Messages rendered as they stream
   - Tool calls shown with expandable args/results
   - Cost and token usage sidebar
3. **Trace view** (`/traces/:run_id`) — Execution tree visualization
   - Recursion tree (nodes = spans, edges = parent-child)
   - Timeline view (horizontal bars for each span)
   - Click a node to see its iterations, tool calls, LLM messages
4. **Trace list** (`/traces`) — All recorded traces, filterable

#### LiveView integration

```elixir
# In the LiveView mount:
Phoenix.PubSub.subscribe(RLM.PubSub, "agent:session:#{session_id}")

# Handle events:
def handle_info(%{event: [:agent, :message, :delta], metadata: meta}, socket) do
  # Append streamed text to the current message display
end

def handle_info(%{event: [:agent, :tool, :start], metadata: meta}, socket) do
  # Show tool execution indicator
end
```

The LiveView consumes the same PubSub events that already exist. No new infrastructure needed — just subscribers.

---

## Phase 6: Enhanced Tracing

### 6.1 Extended telemetry events

Add to `RLM.Telemetry`:

```elixir
@agent_events [
  [:agent, :session, :start],
  [:agent, :session, :stop],
  [:agent, :turn, :start],
  [:agent, :turn, :stop],
  [:agent, :message, :start],
  [:agent, :message, :delta],
  [:agent, :message, :stop],
  [:agent, :tool, :start],
  [:agent, :tool, :stop],
  [:agent, :tool, :error],
  [:agent, :tool, :permission, :requested],
  [:agent, :tool, :permission, :resolved],
  [:agent, :cost, :update],
  [:agent, :context, :compaction]
]
```

### 6.2 Session persistence

**File:** `apps/rlm/lib/agent/session_store.ex`

```elixir
defmodule Agent.SessionStore do
  @moduledoc """
  Persists session state to disk for resumption across restarts.
  Uses JSONL files: one per session in a configurable directory.
  """
  use GenServer

  # On session events, append to JSONL file
  # On load, replay events to reconstruct state
  # Periodic flush (not every event) for performance
end
```

### 6.3 Trace export formats

Extend `RLM.EventLog` with:
- **JSONL** (already exists)
- **HTML export** — Self-contained HTML file with embedded trace viewer (useful for sharing)
- **OpenTelemetry** (future) — Export spans in OTLP format for Jaeger/Grafana

---

## Umbrella Structure (Final)

```
rlm_umbrella/
├── apps/
│   ├── rlm/                    # Core engine (existing + enhanced)
│   │   ├── lib/
│   │   │   ├── rlm/            # Existing RLM modules
│   │   │   └── agent/          # New agent modules
│   │   │       ├── llm.ex
│   │   │       ├── message.ex
│   │   │       ├── session.ex
│   │   │       ├── tool.ex
│   │   │       ├── tool_registry.ex
│   │   │       ├── prompt.ex
│   │   │       ├── permission.ex
│   │   │       ├── session_store.ex
│   │   │       ├── iex.ex
│   │   │       └── tools/
│   │   │           ├── read.ex
│   │   │           ├── write.ex
│   │   │           ├── edit.ex
│   │   │           ├── bash.ex
│   │   │           ├── grep.ex
│   │   │           ├── glob.ex
│   │   │           ├── ls.ex
│   │   │           └── rlm.ex
│   │   ├── test/
│   │   │   ├── agent/          # Agent tests
│   │   │   └── rlm/            # Existing RLM tests
│   │   └── priv/
│   │       ├── system_prompt.md         # RLM prompt (existing)
│   │       └── agent_system_prompt.md   # Agent prompt (new)
│   │
│   └── agent_web/              # LiveView dashboard (new app)
│       ├── lib/
│       │   ├── agent_web/
│       │   │   ├── router.ex
│       │   │   ├── live/
│       │   │   │   ├── session_list_live.ex
│       │   │   │   ├── session_live.ex
│       │   │   │   ├── trace_list_live.ex
│       │   │   │   └── trace_live.ex
│       │   │   └── components/
│       │   │       ├── message_component.ex
│       │   │       ├── tool_call_component.ex
│       │   │       └── trace_tree_component.ex
│       │   └── agent_web.ex
│       └── assets/              # Minimal CSS/JS
│
├── config/
│   ├── config.exs
│   ├── dev.exs
│   └── test.exs
└── mix.exs
```

---

## Implementation Order

### Sprint 1: Foundation (Phases 0 + 1)
1. Fix the 5 issues in Phase 0 (subcall limit, timeout, cleanup, run_id, cost)
2. Implement `Agent.LLM` with tool_use support (non-streaming first)
3. Add streaming support
4. Write tests for LLM client with mock responses

### Sprint 2: Tools (Phase 2)
1. Implement `Agent.Tool` behaviour
2. Build Tool.Read, Tool.Write, Tool.Edit
3. Build Tool.Bash with timeout and truncation
4. Build Tool.Grep, Tool.Glob, Tool.Ls
5. Build Tool.RLM (bridge)
6. Tool registry
7. Test each tool thoroughly

### Sprint 3: Agent Loop (Phase 3)
1. Implement `Agent.Session` GenServer
2. Turn loop: LLM call -> tool execution -> repeat
3. Context compaction
4. Permission model (basic)
5. Integration tests with MockLLM + tool execution

### Sprint 4: Prompt + Interface (Phases 4 + 5)
1. System prompt composition
2. IEx helpers
3. Phoenix LiveView app setup
4. Session list + session view pages
5. Real-time streaming in LiveView

### Sprint 5: Tracing (Phase 6)
1. Extended telemetry events
2. Session persistence
3. Trace visualization in LiveView
4. HTML export

### Sprint 6: Polish + Live API
1. Live API testing with real Claude
2. Error handling edge cases
3. Performance tuning (context compaction, token counting)
4. Documentation

---

## Testing Strategy

### Unit tests (per module)
- Tool implementations: mock filesystem, verify correct behavior
- LLM client: mock HTTP responses (tool_use format)
- Message formatting: verify Anthropic API compliance
- Permission model: verify rules

### Integration tests
- Full turn loop with MockLLM: prompt -> tool_use response -> tool execution -> tool_result -> final response
- Multi-turn conversations
- Context compaction triggers
- RLM bridge: agent invokes RLM, RLM completes, result flows back
- Concurrent sessions

### Live API tests (tagged, excluded by default)
- Simple coding task end-to-end
- Multi-tool task (read file, edit, verify)
- RLM delegation for data processing

### MockLLM extension

Extend `RLM.Test.MockLLM` to support tool_use format responses:

```elixir
# Program a tool_use response
MockLLM.program_responses([
  %{
    content: [
      %{type: "text", text: "Let me read that file."},
      %{type: "tool_use", id: "tool_1", name: "read", input: %{"file_path" => "/tmp/test.txt"}}
    ],
    stop_reason: "tool_use"
  },
  %{
    content: [%{type: "text", text: "The file contains: hello world"}],
    stop_reason: "end_turn"
  }
])
```

---

## Non-Goals (Explicitly Out of Scope)

- Multi-provider support (OpenAI, Google, etc.) — Claude only for now
- TUI / terminal UI — IEx + LiveView is the interface
- OAuth / authentication — API key in env var
- Plugin system — tools are modules, add new ones by writing Elixir
- Image/multimodal support — text only initially
- MCP (Model Context Protocol) — not needed with direct tool implementations
- Git integration as a tool — use bash for git commands
- Automatic project detection / onboarding — manual setup via CLAUDE.md
