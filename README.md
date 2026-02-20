# RLM Umbrella — Recursive Language Model Engine

An Elixir OTP application implementing a recursive code-evaluation AI engine.
The LLM writes Elixir code that runs in a persistent REPL with file/shell tools
available as normal function calls, recursive sub-LLM spawning, and multi-turn
conversation support.

---

## Project structure

```
rlm_umbrella/
├── apps/
│   └── rlm/
│       ├── lib/rlm/
│       │   ├── rlm.ex                  # Public API: RLM.run/3, send_message/3
│       │   ├── worker.ex               # GenServer (iterate loop + multi-turn)
│       │   ├── eval.ex                 # Sandboxed Code.eval_string
│       │   ├── llm.ex                  # Anthropic Messages API client
│       │   ├── sandbox.ex              # Tool wrappers + helpers for eval'd code
│       │   ├── iex.ex                  # IEx convenience helpers
│       │   ├── tool.ex                 # Tool behaviour
│       │   ├── tools/                  # Tool implementations
│       │   │   ├── registry.ex         # Central tool listing
│       │   │   ├── read_file.ex, write_file.ex, edit_file.ex
│       │   │   ├── bash.ex, grep.ex, glob.ex, ls.ex
│       │   ├── event_log.ex            # Per-run trace Agent
│       │   ├── event_log_sweeper.ex    # Periodic EventLog GC
│       │   └── telemetry/              # Telemetry events + handlers
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

## Usage

The RLM engine is a recursive data-processing loop. The LLM writes Elixir code that
runs in a sandboxed REPL with a persistent binding map. It can call itself recursively
via `lm_query/2`, and use file/shell tools as normal function calls.

### From IEx

```bash
iex -S mix
```

```elixir
# Basic usage — synchronous, returns {:ok, answer, span_id}
{:ok, answer, span_id} = RLM.run(
  "line 1\nline 2\nline 3\nline 4",
  "Count the lines and return the count as an integer"
)
# => {:ok, 4, "span-abc123"}

# Async — returns immediately; result arrives as {:rlm_result, span_id, result}
{:ok, run_id, pid} = RLM.run_async(my_large_text, "Summarize the key themes")

# Inspect the execution trace
tree = RLM.EventLog.get_tree(run_id)
jsonl = RLM.EventLog.to_jsonl(run_id)
File.write!("trace.jsonl", jsonl)
```

### Multi-turn conversations

```elixir
import RLM.IEx

# Start a keep-alive session and send first message
{span_id, _response} = start_chat("What Elixir version is this project using?")

# Continue the conversation (bindings persist across turns)
chat(span_id, "Now count the .ex files in lib/")

# Watch live events (iterations + results)
watch(span_id)

# Inspect history and stats
history(span_id)
status(span_id)
```

### Programmatic multi-turn API

```elixir
# Start a keep-alive Worker
{:ok, answer, span_id} = RLM.run(context, query, keep_alive: true)

# Send follow-up messages
{:ok, next_answer} = RLM.send_message(span_id, "Now do something else")

# Check Worker state
info = RLM.status(span_id)
# => %{status: :idle, iteration: 2, message_count: 8, ...}

# Get full message history
messages = RLM.history(span_id)

# Subscribe to PubSub events (for LiveView integration)
Phoenix.PubSub.subscribe(RLM.PubSub, "rlm:worker:#{span_id}")
```

### Configuration overrides

```elixir
{:ok, result, span_id} = RLM.run(context, query,
  max_iterations: 10,
  max_depth: 3,
  model_large: "claude-opus-4-6",
  eval_timeout: 60_000,  # 60 seconds per eval
  keep_alive: true        # Worker stays alive for follow-ups
)
```

### How it works

1. Worker GenServer starts, builds context + query message
2. LLM responds with an `` ```elixir `` code block
3. Code is evaluated in a spawned process (async, with IO capture)
4. Stdout and errors are fed back to the LLM as context
5. LLM iterates until it sets `final_answer = <value>`
6. That value is returned as the result

### Available in the sandbox

Tools are normal Elixir functions, available as bare calls in eval'd code:

```elixir
# Data helpers (from RLM.Helpers)
context                         # String — the input you passed to RLM.run
chunks(context, 1000)           # Stream of 1000-byte chunks
grep("pattern", context)        # List of matching lines (in-memory)
preview(context, 200)           # First N bytes
list_bindings()                 # Inspect current binding state

# Recursive sub-LLM call (spawns a child Worker)
{:ok, result} = lm_query("subset of data", model_size: :small)

# File tools
content = read_file("path/to/file.ex")
write_file("output.txt", "hello world")
edit_file("lib/app.ex", "old_code", "new_code")

# Shell and search tools
output = bash("mix test --trace")
results = grep_files("TODO", glob: "**/*.ex")
files = glob("lib/**/*.ex")
listing = ls("lib/")

# Tool discovery
list_tools()                    # Print all available tools
tool_help(:read_file)           # Print detailed help for a tool
```

---

## Tracing and observability

### Event log

```elixir
{:ok, _result, span_id} = RLM.run(context, query)

# Tree of nodes with per-iteration detail
tree = RLM.EventLog.get_tree(span_id)

# Export as JSONL
jsonl = RLM.EventLog.to_jsonl(span_id)
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
Phoenix.PubSub.subscribe(RLM.PubSub, "rlm:worker:#{span_id}")

# Events: :iteration_start, :iteration_stop, :complete, :error
receive do
  {:rlm_event, :iteration_start, %{iteration: n}} ->
    IO.puts("Iteration #{n} starting...")

  {:rlm_event, :complete, %{result: result}} ->
    IO.puts("Done: #{inspect(result)}")
end
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
{:ok, result, span_id} = RLM.run(
  File.read!("apps/rlm/lib/rlm/worker.ex"),
  "What is the purpose of the pending_subcalls field? Answer in one sentence."
)
IO.puts(result)

# Inspect the trace
RLM.EventLog.get_tree(span_id) |> IO.inspect(pretty: true)

# Interactive multi-turn session
import RLM.IEx
{id, _} = start_chat("Count how many public functions are in apps/rlm/lib/rlm/worker.ex")
chat(id, "Which one has the most complexity?")
```

---

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                      RLM.Supervisor                          │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────────┐  │
│  │ RLM.Registry │  │ RLM.PubSub   │  │ RLM.TaskSupervisor│  │
│  └──────────────┘  └──────────────┘  └──────────────────┘  │
│  ┌──────────────┐  ┌──────────────┐                         │
│  │  WorkerSup   │  │  EventStore  │                         │
│  │ (RLM workers)│  │(trace agents)│                         │
│  └──────────────┘  └──────────────┘                         │
│  ┌──────────────┐  ┌──────────────┐                         │
│  │ RLM.Telemetry│  │EventLog.Sweep│                         │
│  └──────────────┘  └──────────────┘                         │
└─────────────────────────────────────────────────────────────┘

RLM Engine (unified code-eval + tool loop):
  RLM.run/3 → {:ok, answer, span_id}
    → Worker GenServer
      → RLM.LLM.chat (sync)
      → spawn(RLM.Eval.run)
        ↕ {:spawn_subcall} calls
        ↕ Tool calls (read_file, bash, etc.)
      → {:eval_complete, result}
      → Repeat or complete
    → Optional: keep_alive for multi-turn
      → RLM.send_message/2 resumes iterate loop
```

Tools are normal Elixir functions injected via `import RLM.Sandbox` into every
eval'd code block. No JSON schema marshalling — the LLM calls them directly
as part of the Elixir code it writes.
