# CLAUDE.md — RLM (Recursive Language Model) Engine

## Project Structure

This is an Elixir umbrella project at `rlm_umbrella/`.

```
rlm_umbrella/
├── apps/
│   ├── rlm/                    # Core engine (no web framework)
│   │   ├── lib/rlm/
│   │   │   ├── rlm.ex          # Public API: run/3, run_async/3
│   │   │   ├── worker.ex       # RLM GenServer (iterate loop)
│   │   │   ├── eval.ex         # Sandboxed Code.eval_string
│   │   │   ├── llm.ex          # Anthropic Messages API client (RLM path)
│   │   │   ├── helpers.ex      # chunks/2, grep/2, preview/2, list_bindings/0
│   │   │   ├── sandbox.ex      # Bindings injected into eval'd code
│   │   │   ├── prompt.ex       # System prompt + message formatting
│   │   │   ├── config.ex       # Config struct + loader
│   │   │   ├── span.ex         # Span/run ID generation
│   │   │   ├── truncate.ex     # Head+tail string truncation
│   │   │   ├── event_log.ex    # Per-run trace Agent
│   │   │   ├── event_log_sweeper.ex  # Periodic EventLog GC (GenServer)
│   │   │   ├── trace_store.ex  # :dets persistence GenServer
│   │   │   ├── telemetry/      # Telemetry events + handlers
│   │   │   └── agent/
│   │   │       ├── llm.ex          # Anthropic tool_use API + SSE parsing
│   │   │       ├── message.ex      # Message type helpers
│   │   │       ├── session.ex      # Agent GenServer (tool-use loop)
│   │   │       ├── prompt.ex       # Composable system prompt
│   │   │       ├── tool.ex         # Tool behaviour
│   │   │       ├── tool_registry.ex# Tool dispatch + spec assembly
│   │   │       ├── iex.ex          # IEx convenience helpers
│   │   │       └── tools/
│   │   │           ├── read_file.ex
│   │   │           ├── write_file.ex
│   │   │           ├── edit_file.ex
│   │   │           ├── bash.ex
│   │   │           ├── grep.ex
│   │   │           ├── glob.ex
│   │   │           ├── ls.ex
│   │   │           └── rlm_query.ex  # Bridge: agent → RLM engine
│   │   ├── test/
│   │   │   ├── support/        # MockLLM, test helpers
│   │   │   └── rlm/
│   │   │       ├── agent/      # Agent unit + live API tests
│   │   │       ├── integration_test.exs
│   │   │       ├── helpers_test.exs
│   │   │       ├── live_api_test.exs
│   │   │       └── worker_test.exs
│   │   └── priv/
│   │       └── system_prompt.md
│   └── rlm_web/                # Phoenix 1.8 LiveView dashboard (read-only)
│       ├── lib/rlm_web_web/
│       │   ├── live/
│       │   │   ├── run_list_live.ex    # GET /
│       │   │   └── run_detail_live.ex  # GET /runs/:run_id
│       │   ├── components/
│       │   │   ├── core_components.ex
│       │   │   └── trace_components.ex # span_node, iteration_card
│       │   ├── router.ex
│       │   └── endpoint.ex
│       └── test/
│           └── rlm_web_web/live/
├── config/
│   ├── config.exs
│   ├── dev.exs
│   ├── test.exs
│   └── runtime.exs
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
├── RLM.TraceStore  (GenServer)            ← :dets persistence (rlm_traces table)
└── RLM.EventLog.Sweeper (GenServer)       ← GCs stale trace agents + :dets TTL sweep
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
| `RLM.EventLog.Sweeper` | GenServer; periodically GCs stale EventLog agents + :dets TTL sweep |
| `RLM.TraceStore` | GenServer owning `:dets` table; persists events across restarts |
| `RLM.Telemetry` | Handler attachment GenServer |
| `RLM.Telemetry.Logger` | Structured logging handler |
| `RLM.Telemetry.PubSub` | Phoenix.PubSub broadcast handler |
| `RLM.Telemetry.EventLogHandler` | Routes telemetry events to EventLog Agent AND TraceStore |

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

### Dashboard (apps/rlm_web)

Read-only Phoenix LiveView app. Reuses `RLM.PubSub` started by the rlm app.
Start with `mix phx.server` from umbrella root; serves on `http://localhost:4000`.

| Module | Purpose |
|---|---|
| `RlmWebWeb.RunListLive` | `/` — list of all runs (from TraceStore + live PubSub updates) |
| `RlmWebWeb.RunDetailLive` | `/runs/:run_id` — recursive span tree with expandable iterations |
| `RlmWebWeb.TraceComponents` | HEEx components: `span_node/1`, `iteration_card/1` |
| `RlmWebWeb.Endpoint` | Phoenix endpoint using `RLM.PubSub` as pubsub_server |

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
| `agent_llm_module` | `RLM.Agent.LLM` | Swappable LLM for the coding agent; inject `MockAgentLLM` in session tests |

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

## Orientation for Coding Agents

When starting a task, read these files in order:

1. **`CLAUDE.md`** (this file) — architecture, invariants, module map
2. **`config/config.exs`** — runtime defaults
3. The specific module(s) relevant to your task (see Module Map above)
4. The corresponding test file to understand expected behaviour

Key invariants **never to break**:
- Raw input data must not enter any LLM context window (use `preview/2` or metadata only)
- Workers are `:temporary` — do not change their restart strategy
- The async-eval pattern in `RLM.Worker` is intentional; do not make eval synchronous
- All session tests must use `async: false` (MockLLM is global ETS state)

Before committing, always run:
```bash
# From the umbrella root
mix compile --warnings-as-errors
mix test
mix format --check-formatted
```

If you add or modify a public function, run `mix docs` from `apps/rlm/` to verify ExDoc
compiles cleanly (warnings indicate missing or broken `@doc` / `@spec` annotations).

## Feature Development Checklist

When implementing a new feature or making a significant change, update the following
documentation artifacts **as part of the same commit or PR**:

### Always update

- [ ] **`CLAUDE.md` — Module Map** — add a row for every new module you create
- [ ] **`CLAUDE.md` — Config Fields** — add a row for every new `RLM.Config` field
- [ ] **`CHANGELOG.md`** — add an entry under `## [Unreleased]` describing what changed
      and why; follow the existing format (Added / Changed / Fixed / Removed)

### Update when the public API changes

- [ ] **`README.md`** — update usage examples, return-value descriptions, or the
      supervision-tree diagram if the OTP structure changed

### Update for significant architectural changes

- [ ] **`GUIDE.html`** — regenerate by asking a subagent to produce an updated
      self-contained HTML architecture reference based on the current source files;
      commit the result to the repo root

### Regenerate ExDoc

```bash
cd apps/rlm
mix docs        # output: apps/rlm/doc/
```

Commit the regenerated `doc/` only if the project tracks it (check `.gitignore`).
Otherwise just verify it builds cleanly.

### Checklist summary (copy-paste ready)

```
- [ ] CLAUDE.md module map updated
- [ ] CLAUDE.md config fields updated (if new config keys added)
- [ ] CHANGELOG.md entry added
- [ ] README.md updated (if public API changed)
- [ ] mix compile --warnings-as-errors passes
- [ ] mix test passes
- [ ] mix format --check-formatted passes
- [ ] mix docs builds cleanly
```
