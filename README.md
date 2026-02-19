# RLM Umbrella — Recursive Language Model + OTP Coding Agent

An Elixir umbrella project implementing two complementary AI execution engines:

1. **RLM Engine** — a recursive code-evaluation loop where the LLM writes Elixir code that runs in a persistent REPL, with recursive sub-LLM spawning
2. **Coding Agent** — a tool-use loop (Pi-agent philosophy) where the LLM calls structured tools (read file, write file, bash, etc.) in a GenServer session

Both engines share OTP infrastructure: Registry, PubSub, DynamicSupervisors, and a Telemetry pipeline.

---

## Project structure

```
rlm_umbrella/
├── apps/
│   └── rlm/
│       ├── lib/rlm/
│       │   ├── rlm.ex                  # Public API: RLM.run/3
│       │   ├── worker.ex               # RLM GenServer (iterate loop)
│       │   ├── eval.ex                 # Sandboxed Code.eval_string
│       │   ├── llm.ex                  # Anthropic Messages API client (RLM path)
│       │   ├── event_log.ex            # Per-run trace Agent
│       │   ├── event_log_sweeper.ex    # Periodic EventLog GC
│       │   ├── telemetry/              # Telemetry events + handlers
│       │   └── agent/
│       │       ├── llm.ex              # Anthropic tool_use API + SSE streaming
│       │       ├── message.ex          # Message type helpers
│       │       ├── session.ex          # Agent GenServer (tool-use loop)
│       │       ├── prompt.ex           # Composable system prompt
│       │       ├── tool.ex             # Tool behaviour
│       │       ├── tool_registry.ex    # Tool dispatch + spec assembly
│       │       ├── iex.ex              # IEx convenience helpers
│       │       └── tools/
│       │           ├── read_file.ex
│       │           ├── write_file.ex
│       │           ├── edit_file.ex
│       │           ├── bash.ex
│       │           ├── grep.ex
│       │           ├── glob.ex
│       │           ├── ls.ex
│       │           └── rlm_query.ex    # Bridge: agent → RLM engine
│       ├── priv/
│       │   ├── system_prompt.md        # RLM engine system prompt
│       │   └── soul.md                 # Agent identity + behavioural guidelines
│       └── test/
└── config/config.exs
```

---

## Prerequisites

- Elixir ≥ 1.19 / OTP 27
- `CLAUDE_API_KEY` environment variable (Anthropic API key)

```bash
export CLAUDE_API_KEY=sk-ant-...
```

---

## Build and test

```bash
# Install dependencies
mix deps.get

# Compile
mix compile

# Run tests (live API tests excluded by default)
mix test

# Run all tests including live API (requires CLAUDE_API_KEY)
mix test --include live_api
```

---

## Using the RLM Engine

The RLM engine is a recursive data-processing loop. The LLM writes Elixir code that
runs in a sandboxed REPL with a persistent binding map. It can call itself recursively
via `lm_query/2`.

### From IEx

```bash
iex -S mix
```

```elixir
# Basic usage — synchronous, returns {:ok, answer, run_id}
{:ok, answer, run_id} = RLM.run(
  "line 1\nline 2\nline 3\nline 4",
  "Count the lines and return the count as an integer"
)
# => {:ok, 4, "run-abc123"}

# Async — returns immediately; result arrives as {:rlm_result, span_id, result}
{:ok, run_id, pid} = RLM.run_async(my_large_text, "Summarize the key themes")

# Inspect the execution trace
tree = RLM.EventLog.get_tree(run_id)
jsonl = RLM.EventLog.to_jsonl(run_id)
File.write!("trace.jsonl", jsonl)
```

### Configuration overrides

```elixir
{:ok, result, run_id} = RLM.run(context, query,
  max_iterations: 10,
  max_depth: 3,
  model_large: "claude-opus-4-6",
  eval_timeout: 60_000  # 60 seconds per eval
)
```

### How it works

1. Worker GenServer starts, builds context + query message
2. LLM responds with an `` ```elixir `` code block
3. Code is evaluated in a spawned process (async, with IO capture)
4. Stdout and errors are fed back to the LLM as context
5. LLM iterates until it sets `final_answer = <value>`
6. That value is returned as the result

Available in the sandbox:

```elixir
context           # String — the input you passed to RLM.run

chunks(context, 1000)        # Stream of 1000-byte chunks
grep("pattern", context)     # List of matching lines
preview(context, 200)        # First N bytes
list_bindings()              # Inspect current binding state

# Recursive sub-LLM call (spawns a child Worker)
{:ok, result} = lm_query("subset of data", model_size: :small)
```

---

## Using the Coding Agent

The coding agent uses Anthropic's native `tool_use` API. It can read/write files,
run bash commands, search code, and delegate complex data tasks to the RLM engine.

### From IEx

```bash
iex -S mix
```

```elixir
import RLM.Agent.IEx

# Start a session and send first message in one step
{session, _response} = start_chat("What Elixir version is this project using?")

# Continue the conversation
chat(session, "Now show me the supervision tree")

# Watch live events (tool calls + streaming text)
watch(session)

# Inspect history and stats
history(session)
status(session)
```

### Programmatic API

```elixir
# Start a session
{:ok, _pid} = DynamicSupervisor.start_child(RLM.AgentSup, {
  RLM.Agent.Session,
  [
    session_id: "my-session",
    system_prompt: RLM.Agent.Prompt.build(cwd: File.cwd!()),
    tools: RLM.Agent.ToolRegistry.specs(),
    stream: true
  ]
})

# Subscribe to real-time events
Phoenix.PubSub.subscribe(RLM.PubSub, "agent:session:my-session")

# Send a message
{:ok, response} = RLM.Agent.Session.send_message("my-session", "Run the test suite")

# Receive events
receive do
  {:agent_event, :text_chunk, %{text: chunk}} -> IO.write(chunk)
  {:agent_event, :tool_call_start, %{call: call}} -> IO.inspect(call)
  {:agent_event, :turn_complete, %{response: text}} -> IO.puts(text)
end
```

### Available tools

| Tool | Description |
|------|-------------|
| `read_file` | Read file contents (up to 100 KB) |
| `write_file` | Write or overwrite a file |
| `edit_file` | Exact-string replacement (uniqueness-guarded) |
| `bash` | Run shell commands (timeout-protected via Task) |
| `grep` | ripgrep search with glob filtering |
| `glob` | Find files by pattern |
| `ls` | List directory contents with sizes |
| `rlm_query` | Delegate data processing to the RLM engine |

---

## Tracing and observability

### Event log (RLM engine)

```elixir
{:ok, _result, run_id} = RLM.run(context, query)

# Tree of nodes with per-iteration detail
tree = RLM.EventLog.get_tree(run_id)

# Export as JSONL
jsonl = RLM.EventLog.to_jsonl(run_id)
File.write!("trace.jsonl", jsonl)
```

### Telemetry events

14 events fire during RLM execution. Attach your own handler:

```elixir
:telemetry.attach("my-handler", [:rlm, :iteration, :stop],
  fn _event, measurements, meta, _ ->
    IO.puts("Iteration #{meta.iteration} — #{measurements.duration_ms}ms")
  end, nil)
```

Event families: `[:rlm, :node, :*]`, `[:rlm, :iteration, :*]`,
`[:rlm, :llm, :request, :*]`, `[:rlm, :eval, :*]`,
`[:rlm, :subcall, :*]`, `[:rlm, :compaction, :run]`

### PubSub live stream

```elixir
# Agent session events
Phoenix.PubSub.subscribe(RLM.PubSub, "agent:session:#{session_id}")

# Events: :turn_start, :text_chunk, :tool_call_start,
#         :tool_call_end, :turn_complete, :error
```

---

## Running a real test

With `CLAUDE_API_KEY` set:

```bash
# Run live API tests
mix test --include live_api
```

From IEx:

```elixir
iex -S mix

# Test the RLM engine on a real file
{:ok, result, run_id} = RLM.run(
  File.read!("apps/rlm/lib/rlm/worker.ex"),
  "What is the purpose of the pending_subcalls field? Answer in one sentence."
)
IO.puts(result)

# Inspect the trace
RLM.EventLog.get_tree(run_id) |> IO.inspect(pretty: true)

# Test the coding agent
import RLM.Agent.IEx
{session, _} = start_chat("Count how many public functions are in apps/rlm/lib/rlm/worker.ex")
```

---

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                      RLM.Supervisor                          │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────────┐  │
│  │ RLM.Registry │  │ RLM.PubSub   │  │ RLM.TaskSupervisor│  │
│  └──────────────┘  └──────────────┘  └──────────────────┘  │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────────┐  │
│  │  WorkerSup   │  │  EventStore  │  │    AgentSup      │  │
│  │ (RLM workers)│  │(trace agents)│  │ (agent sessions) │  │
│  └──────────────┘  └──────────────┘  └──────────────────┘  │
│  ┌──────────────┐  ┌──────────────┐                         │
│  │ RLM.Telemetry│  │EventLog.Sweep│                         │
│  └──────────────┘  └──────────────┘                         │
└─────────────────────────────────────────────────────────────┘

RLM Engine (code-eval loop):          Coding Agent (tool-use loop):
  RLM.run/3 → {:ok, answer, run_id}    RLM.Agent.Session.send_message/3
    → Worker GenServer                    → Agent.LLM.call/4 (tool_use API)
      → RLM.LLM.chat (sync)               → Tool execution (parallel)
      → spawn(RLM.Eval.run)               → Append tool results
        ↕ {:spawn_subcall} calls          → LLM again...
      → {:eval_complete, result}          → Final text response
      → Repeat or complete
```

The **`rlm_query` tool** connects both engines: the coding agent can delegate
heavy data-processing to the RLM engine, which handles it with its persistent
Elixir REPL loop. This is the key architectural integration point.
