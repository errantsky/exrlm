# CLAUDE.md — RLM (Recursive Language Model) Engine

## Project Structure

This is an Elixir umbrella project at `rlm_umbrella/`.

```
rlm_umbrella/
├── apps/
│   └── rlm/                    # Core engine (no web framework)
│       ├── lib/rlm/
│       │   ├── rlm.ex          # Public API: run/3, run_async/3
│       │   ├── worker.ex       # RLM GenServer (iterate loop)
│       │   ├── eval.ex         # Sandboxed Code.eval_string
│       │   ├── llm.ex          # Anthropic Messages API client (RLM path)
│       │   ├── helpers.ex      # chunks/2, grep/2, preview/2, list_bindings/0
│       │   ├── sandbox.ex      # Bindings injected into eval'd code
│       │   ├── prompt.ex       # System prompt + message formatting
│       │   ├── config.ex       # Config struct + loader
│       │   ├── span.ex         # Span/run ID generation
│       │   ├── truncate.ex     # Head+tail string truncation
│       │   ├── event_log.ex    # Per-run trace Agent
│       │   ├── event_log_sweeper.ex  # Periodic EventLog GC (GenServer)
│       │   ├── telemetry/      # Telemetry events + handlers
│       │   └── agent/
│       │       ├── llm.ex          # Anthropic tool_use API + SSE parsing
│       │       ├── message.ex      # Message type helpers
│       │       ├── session.ex      # Agent GenServer (tool-use loop)
│       │       ├── prompt.ex       # Composable system prompt
│       │       ├── tool.ex         # Tool behaviour
│       │       ├── tool_registry.ex# Tool dispatch + spec assembly
│       │       ├── iex.ex          # IEx convenience helpers
│       │       └── tools/
│       │           ├── read_file.ex
│       │           ├── write_file.ex
│       │           ├── edit_file.ex
│       │           ├── bash.ex
│       │           ├── grep.ex
│       │           ├── glob.ex
│       │           ├── ls.ex
│       │           └── rlm_query.ex  # Bridge: agent → RLM engine
│       ├── test/
│       │   ├── support/        # MockLLM, test helpers
│       │   └── rlm/
│       │       ├── agent/      # Agent unit + live API tests
│       │       ├── integration_test.exs
│       │       ├── helpers_test.exs
│       │       ├── live_api_test.exs
│       │       └── worker_test.exs
│       └── priv/
│           └── agent_system_prompt.md
├── config/
│   └── config.exs
└── mix.exs
```

## Build & Run

```bash
# Install dependencies
mix deps.get

# Compile
mix compile

# Run tests (excludes live API tests by default)
mix test

# Run tests with trace output
mix test --trace

# Run live API tests (requires CLAUDE_API_KEY env var)
mix test --include live_api

# Interactive shell
iex -S mix
```

## Key Design Decisions

### Async Eval Pattern (Critical)
The Worker GenServer spawns eval in a separate process so the Worker mailbox stays free
to handle `{:spawn_subcall, ...}` calls from eval'd code. This prevents deadlock:
- Worker receives `:iterate` → calls LLM synchronously → spawns eval async
- Eval'd code may call `lm_query()` → `GenServer.call(worker_pid, {:spawn_subcall, ...})`
- Worker handles the subcall, spawns a child Worker, stores `from` in `pending_subcalls`
- Child result arrives as `{:rlm_result, child_span_id, result}` → Worker replies to blocked caller
- Eval finishes → sends `{:eval_complete, result}` → Worker processes the result

### Three Invariants
1. Raw input data never enters the LLM context window — only metadata/preview
2. Sub-LLM outputs stay in variables, never shown to parent LLM directly
3. Stdout is truncated with head+tail strategy

### OTP Supervision Tree
```
RLM.Supervisor (one_for_one)
├── Registry      (RLM.Registry)
├── Phoenix.PubSub (RLM.PubSub)
├── Task.Supervisor (RLM.TaskSupervisor)   ← bash tool, session tasks
├── DynamicSupervisor (RLM.WorkerSup)      ← Workers are :temporary
├── DynamicSupervisor (RLM.EventStore)     ← EventLog Agents
├── DynamicSupervisor (RLM.AgentSup)       ← coding agent sessions
├── RLM.Telemetry   (GenServer)
└── RLM.EventLog.Sweeper (GenServer)       ← GCs stale trace agents
```

### RLM.run/3 Return Value
`RLM.run/3` returns `{:ok, answer, run_id}` (3-tuple). The `run_id` can be used to
retrieve the execution trace via `RLM.EventLog`. On failure it returns `{:error, reason}`.
A `Process.monitor` on the Worker ensures crashes surface as errors rather than hangs.

### SSE Streaming (Coding Agent)
`RLM.Agent.LLM` sends `stream: true` to Anthropic, which responds in SSE format. Rather
than using Req's `into:` option (which conflicts with Finch's adapter contract in Req
0.5.x), the full SSE response body is buffered as a binary and then parsed synchronously.
Anthropic closes the connection after `message_stop`, so no indefinite blocking occurs.
`on_chunk` callbacks fire during parsing (post-receipt). A future LiveView integration
can add real-time streaming via a different transport layer.

### LLM Client
Both engines use the Anthropic Messages API (not OpenAI format). System messages are
extracted and sent as the top-level `system` field. Requires `CLAUDE_API_KEY` env var.

Default models:
- Large: `claude-sonnet-4-5-20250929`
- Small: `claude-haiku-4-5-20251001`

## Module Map

### RLM Engine

| Module | Purpose |
|---|---|
| `RLM` | Public API: `run/3` → `{:ok, answer, run_id}`, `run_async/3` |
| `RLM.Config` | Config struct; loads from app env + keyword overrides |
| `RLM.Worker` | GenServer per execution node; drives the iterate loop |
| `RLM.Eval` | Sandboxed `Code.eval_string` with async IO capture |
| `RLM.Sandbox` | Functions injected into eval'd code (`lm_query`, `chunks`, etc.) |
| `RLM.LLM` | Anthropic Messages API client + code-block extraction |
| `RLM.Prompt` | System prompt loading and user/assistant message formatting |
| `RLM.Helpers` | `chunks/2`, `grep/2`, `preview/2`, `list_bindings/0` |
| `RLM.Truncate` | Head+tail string truncation for stdout overflow |
| `RLM.Span` | Span/run ID generation |
| `RLM.EventLog` | Per-run Agent storing structured reasoning trace |
| `RLM.EventLog.Sweeper` | GenServer; periodically GCs stale EventLog agents |
| `RLM.Telemetry` | Handler attachment GenServer |
| `RLM.Telemetry.Logger` | Structured logging handler |
| `RLM.Telemetry.PubSub` | Phoenix.PubSub broadcast handler |
| `RLM.Telemetry.EventLogHandler` | Routes telemetry events to EventLog Agent |

### Coding Agent

| Module | Purpose |
|---|---|
| `RLM.Agent.LLM` | Anthropic tool_use API client; parses SSE response body |
| `RLM.Agent.Message` | Message constructors and API serialisation helpers |
| `RLM.Agent.Session` | GenServer; multi-turn tool-use loop with PubSub events |
| `RLM.Agent.Prompt` | Composable system prompt builder (`build/1`) |
| `RLM.Agent.Tool` | `@behaviour` with `spec/0` and `execute/1` callbacks |
| `RLM.Agent.ToolRegistry` | Lists all tools; provides `specs/0`, `execute/2` |
| `RLM.Agent.IEx` | `start/1`, `chat/3`, `start_chat/2`, `watch/2`, `history/1`, `status/1` |
| `RLM.Agent.Tools.ReadFile` | Read file contents (≤ 100 KB) |
| `RLM.Agent.Tools.WriteFile` | Write or overwrite a file (creates parents) |
| `RLM.Agent.Tools.EditFile` | Exact-string replacement (uniqueness-guarded) |
| `RLM.Agent.Tools.Bash` | Shell commands via `Task.yield` timeout guard |
| `RLM.Agent.Tools.Grep` | ripgrep search with glob filtering |
| `RLM.Agent.Tools.Glob` | Find files by pattern |
| `RLM.Agent.Tools.Ls` | List directory with sizes |
| `RLM.Agent.Tools.RlmQuery` | Bridge: delegate to RLM engine from agent |

## Config Fields

| Field | Default | Notes |
|---|---|---|
| `model_large` | `claude-sonnet-4-5-20250929` | Used for parent workers |
| `model_small` | `claude-haiku-4-5-20251001` | Used for subcalls |
| `max_iterations` | `25` | Per-worker LLM turn limit |
| `max_depth` | `5` | Recursive subcall depth limit |
| `max_concurrent_subcalls` | `10` | Parallel subcall limit per worker |
| `eval_timeout` | `300_000` | ms per eval (5 min) |
| `llm_timeout` | `120_000` | ms per LLM request (2 min) |
| `llm_module` | `RLM.LLM` | Swappable for `RLM.Test.MockLLM` |

## Testing Conventions

- Tests use `RLM.Test.MockLLM` (global ETS-based response queue) for deterministic testing
- All tests run `async: false` since MockLLM uses global state
- Live API tests tagged with `@moduletag :live_api` and excluded by default
- `mix test --include live_api` requires `CLAUDE_API_KEY` env var
- Test support files in `apps/rlm/test/support/`
- Agent tool tests use a per-test temp directory (created in `setup`, cleaned in `on_exit`)
- Worker concurrency/depth tests spawn real Workers via `DynamicSupervisor`

## Important Notes

- `Code.eval_string` in `RLM.Eval` is intentional — it is the core REPL mechanism
- Workers use `restart: :temporary` — they terminate normally after completion
- The `llm_module` config field enables dependency injection for testing
- Bash tool uses `Task.async` + `Task.yield/2` (not `System.cmd` — it has no `:timeout` option)
- `.env` file with `CLAUDE_API_KEY` should exist at project root but must not be committed
- `RLM.run/3` monitors the Worker with `Process.monitor` so crashes return `{:error, reason}`
  rather than hanging indefinitely
