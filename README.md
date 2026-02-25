# RLM — Recursive Language Model Engine

This project is my exploration of coding agents and Recursive Language Models, built in
Elixir because OTP's supervision trees and process model felt like a natural fit for
managing recursive LLM spawning. I was inspired by a few things: the
[RLM paper](https://alexzhang13.github.io/blog/2025/rlm/) and its idea of LLMs writing
code in a loop, [Jbollenbacher's Elixir RLM](https://github.com/Jbollenbacher/RLM) which
I wanted to take further, and the design philosophy behind
[pi](https://github.com/badlogic/pi-mono/) — a coding agent that keeps things simple and
transparent. This is very much a learning project, but it works and it's been fun to build.

A single Phoenix application implementing a unified AI execution engine where the LLM writes
Elixir code that runs in a persistent REPL, with recursive sub-LLM spawning, built-in
filesystem tools, and compile-time architecture enforcement via
[`boundary`](https://hex.pm/packages/boundary).

**One engine, two modes:**
1. **One-shot** — `RLM.run/3` processes data and returns a result
2. **Interactive** — `RLM.start_session/1` + `send_message/3` for multi-turn sessions with persistent bindings

---

## Project structure

```
rlm/
├── lib/
│   ├── rlm.ex                    # Public API: run/3, start_session/1, send_message/3
│   ├── rlm/                      # Core engine
│   │   ├── application.ex        # Unified OTP application (core + web)
│   │   ├── worker.ex             # GenServer (iterate loop + keep_alive)
│   │   ├── run.ex                # Per-run coordinator GenServer
│   │   ├── eval.ex               # Sandboxed Code.eval_string
│   │   ├── llm.ex                # Anthropic Messages API client
│   │   ├── sandbox.ex            # Eval sandbox (helpers + tools)
│   │   ├── iex.ex                # IEx convenience helpers
│   │   ├── tool.ex               # Tool behaviour
│   │   ├── tool_registry.ex      # Tool dispatch + discovery
│   │   ├── telemetry/            # Telemetry events + handlers
│   │   └── tools/                # 7 filesystem tools
│   ├── rlm_web.ex                # Phoenix web module
│   └── rlm_web/                  # Phoenix LiveView dashboard
├── test/
├── config/
├── assets/                       # JS, CSS, vendor (esbuild + tailwind)
├── priv/
│   ├── static/                   # Built assets
│   └── system_prompt.md          # LLM system prompt
└── examples/                     # Smoke tests and example scenarios
```

### Architecture boundaries

Enforced at compile time via `boundary`:

- **`RLM`** — Core engine. Zero web dependencies.
- **`RLMWeb`** — Phoenix web layer. Depends only on `RLM`.
- **`RLM.Application`** — Top-level. Starts the unified supervision tree.

---

## Prerequisites

- Elixir >= 1.19 / OTP 27
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

# Live smoke test (5 end-to-end tests against the real API)
mix rlm.smoke
```

---

## Using the RLM Engine

### One-shot mode

The LLM writes Elixir code that runs in a sandboxed REPL with a persistent binding map.
It can call itself recursively via `lm_query/2`.

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
```

### Interactive sessions

Multi-turn sessions where bindings persist across turns. The Worker stays alive
between messages, and filesystem tools are available in the sandbox.

```elixir
# Start a session
{:ok, sid} = RLM.start_session(cwd: ".")

# Send messages — each returns {:ok, answer} when the LLM sets final_answer
{:ok, answer1} = RLM.send_message(sid, "List files in the current directory using bash")
{:ok, answer2} = RLM.send_message(sid, "Now read the README")

# Introspection
RLM.history(sid)    # Full message history
RLM.status(sid)     # Session status map
```

### IEx helpers

```elixir
import RLM.IEx

# Start a session and send first message in one step
{session, _response} = start_chat("What Elixir version is this project using?")

# Continue the conversation
chat(session, "Now show me the supervision tree")

# Watch live telemetry events
watch(session)

# Inspect history and stats
history(session)
status(session)
```

### Distributed Erlang

Connect multiple RLM nodes for remote execution:

```elixir
# Start distribution (auto-configures from RLM_NODE_NAME / RLM_COOKIE env vars)
RLM.Node.start()
# => {:ok, :rlm@hostname}

# Check distribution status
RLM.Node.info()
# => %RLM.Node.Info{node: :rlm@hostname, alive: true, cookie: :rlm_dev, ...}

# Execute on a remote node (uses :erpc — modern OTP)
RLM.Node.rpc(:"rlm@other_host", Kernel, :+, [1, 2])
# => {:ok, 3}

# Run an RLM query on a remote node (IEx helper)
import RLM.IEx
remote(:"rlm@other_host", "Summarize the key themes")
# => {:ok, "summary of themes...", "run-abc123"}
```

For releases, distribution is configured via environment variables:

```bash
RLM_NODE_NAME=rlm   # Defaults to release name
RLM_COOKIE=secret    # Shared secret for node authentication
```

### Configuration overrides

```elixir
{:ok, result, run_id} = RLM.run(context, query,
  max_iterations: 10,
  max_depth: 3,
  model_large: "claude-opus-4-6",
  eval_timeout: 60_000
)
```

### Sandbox functions

Available inside the REPL sandbox (both one-shot and interactive modes):

```elixir
# Data helpers
context               # String — the input data (one-shot mode only)
chunks(context, 1000) # Stream of 1000-byte chunks
grep("pattern", ctx)  # In-memory string search: [{line_num, line}]
preview(term, 200)    # Truncated inspect
list_bindings()       # Current bindings info

# LLM sub-calls (recursive)
{:ok, result} = lm_query("subset of data", model_size: :small)
results = parallel_query(["chunk1", "chunk2"], model_size: :small)

# Structured extraction (schema mode) — single direct LLM call, returns parsed map
schema = %{"type" => "object", "properties" => %{"names" => %{"type" => "array", "items" => %{"type" => "string"}}}, "required" => ["names"]}
{:ok, %{"names" => names}} = lm_query("Extract names from: #{text}", schema: schema)

# Filesystem tools
{:ok, content} = read_file("path/to/file.ex")
{:ok, _} = write_file("output.txt", "content")
{:ok, _} = edit_file("file.ex", "old text", "new text")
{:ok, output} = bash("mix test")
{:ok, matches} = rg("defmodule", "lib/")
{:ok, files} = find_files("**/*.ex")
{:ok, listing} = ls()
```

---

## Tracing and observability

### Event log

```elixir
{:ok, _result, run_id} = RLM.run(context, query)

tree = RLM.EventLog.get_tree(run_id)
jsonl = RLM.EventLog.to_jsonl(run_id)
File.write!("trace.jsonl", jsonl)
```

### Telemetry events

17 events fire during RLM execution. Attach your own handler:

```elixir
:telemetry.attach("my-handler", [:rlm, :iteration, :stop],
  fn _event, measurements, meta, _ ->
    IO.puts("Iteration #{meta.iteration} — #{measurements.duration_ms}ms")
  end, nil)
```

Event families: `[:rlm, :node, :*]`, `[:rlm, :iteration, :*]`,
`[:rlm, :llm, :request, :*]`, `[:rlm, :eval, :*]`,
`[:rlm, :subcall, :*]`, `[:rlm, :direct_query, :*]`,
`[:rlm, :compaction, :run]`, `[:rlm, :turn, :complete]`

### PubSub live stream

```elixir
# Subscribe to all runs
Phoenix.PubSub.subscribe(RLM.PubSub, "rlm:runs")

# Subscribe to a specific run
Phoenix.PubSub.subscribe(RLM.PubSub, "rlm:run:#{run_id}")
```

---

## Architecture

```
┌───────────────────────────────────────────────────────────────┐
│                       RLM.Supervisor                          │
│                                                               │
│  Core engine ─────────────────────────────────────────────    │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────────┐    │
│  │ RLM.Registry │  │ RLM.PubSub   │  │RLM.TaskSupervisor│    │
│  └──────────────┘  └──────────────┘  └──────────────────┘    │
│  ┌──────────────┐  ┌──────────────┐                           │
│  │   RunSup     │  │  EventStore  │                           │
│  │ (per-run     │  │(trace agents)│                           │
│  │  coordinators│  └──────────────┘                           │
│  │  + workers)  │                                             │
│  └──────────────┘                                             │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────────┐    │
│  │ RLM.Telemetry│  │ TraceStore   │  │EventLog.Sweeper  │    │
│  └──────────────┘  └──────────────┘  └──────────────────┘    │
│                                                               │
│  Web dashboard ───────────────────────────────────────────    │
│  ┌──────────────────┐  ┌──────────────┐  ┌──────────────┐    │
│  │RLMWeb.Telemetry  │  │  DNSCluster  │  │RLMWeb.Endpoint│   │
│  └──────────────────┘  └──────────────┘  └──────────────┘    │
└───────────────────────────────────────────────────────────────┘

One-shot mode (RLM.run/3):             Interactive mode (start_session/1):
  Worker starts → iterate loop            Worker starts idle
    → LLM chat (sync)                     → send_message triggers iteration
    → spawn eval (async)                  → LLM chat → eval → final_answer
      ↕ subcall requests                  → Reply to caller, reset to idle
    → final_answer → terminate            → Bindings persist for next turn
```

Tools live inside the sandbox — the eval'd code calls `read_file/1`, `bash/1`,
`rg/1` etc. directly. No separate tool-use protocol needed.

---

## Security

RLM executes LLM-generated Elixir code via `Code.eval_string` with full access to the
host filesystem, network, and shell. **Do not expose RLM to untrusted users or untrusted
LLM providers.** It is designed for local development, trusted API backends (Anthropic),
and controlled environments. There is no sandboxing beyond process-level isolation and
configurable timeouts.

---

## License

This project is licensed under the [MIT License](LICENSE).

---

## Further reading

For a comprehensive architecture reference — OTP supervision tree, async-eval pattern,
module map, telemetry events, configuration, and known limitations — see
[`docs/GUIDE.html`](docs/GUIDE.html).
