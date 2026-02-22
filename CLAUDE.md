# CLAUDE.md — RLM (Recursive Language Model) Engine

## Project Structure

This is an Elixir umbrella project at `rlm_umbrella/`.

```
rlm_umbrella/
├── apps/
│   ├── rlm/                    # Core engine (no web framework)
│   │   ├── lib/rlm/
│   │   │   ├── rlm.ex          # Public API: run/3, start_session/1, send_message/3
│   │   │   ├── worker.ex       # RLM GenServer (iterate loop + keep_alive mode)
│   │   │   ├── eval.ex         # Sandboxed Code.eval_string
│   │   │   ├── llm.ex          # Anthropic Messages API client
│   │   │   ├── helpers.ex      # chunks/2, grep/2, preview/2, list_bindings/0
│   │   │   ├── sandbox.ex      # Eval sandbox: helpers + LLM calls + tool wrappers
│   │   │   ├── prompt.ex       # System prompt + message formatting
│   │   │   ├── config.ex       # Config struct + loader
│   │   │   ├── span.ex         # Span/run ID generation
│   │   │   ├── truncate.ex     # Head+tail string truncation
│   │   │   ├── iex.ex          # IEx convenience helpers
│   │   │   ├── event_log.ex    # Per-run trace Agent
│   │   │   ├── event_log_sweeper.ex  # Periodic EventLog GC (GenServer)
│   │   │   ├── trace_store.ex  # :dets persistence GenServer
│   │   │   ├── tool.ex         # Tool behaviour
│   │   │   ├── tool_registry.ex # Tool dispatch + discovery
│   │   │   ├── telemetry/      # Telemetry events + handlers
│   │   │   └── tools/
│   │   │       ├── read_file.ex
│   │   │       ├── write_file.ex
│   │   │       ├── edit_file.ex
│   │   │       ├── bash.ex
│   │   │       ├── grep.ex
│   │   │       ├── glob.ex
│   │   │       └── ls.ex
│   │   ├── test/
│   │   │   ├── support/        # MockLLM, test helpers
│   │   │   └── rlm/
│   │   │       ├── tools_test.exs
│   │   │       ├── sandbox_test.exs
│   │   │       ├── worker_keep_alive_test.exs
│   │   │       ├── worker_pubsub_test.exs
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
├── Task.Supervisor (RLM.TaskSupervisor)   ← bash tool tasks
├── DynamicSupervisor (RLM.WorkerSup)      ← Workers (:temporary) — one-shot + keep_alive
├── DynamicSupervisor (RLM.EventStore)     ← EventLog Agents
├── RLM.Telemetry   (GenServer)
├── RLM.TraceStore  (GenServer)            ← :dets persistence (rlm_traces table)
└── RLM.EventLog.Sweeper (GenServer)       ← GCs stale trace agents + :dets TTL sweep
```

### RLM.run/3 Return Value
`RLM.run/3` returns `{:ok, answer, run_id}` (3-tuple). The `run_id` can be used to
retrieve the execution trace via `RLM.EventLog`. On failure it returns `{:error, reason}`.
A `Process.monitor` on the Worker ensures crashes surface as errors rather than hangs.

### LLM Client
Uses the Anthropic Messages API (not OpenAI format). System messages are
extracted and sent as the top-level `system` field. Requires `CLAUDE_API_KEY` env var.

LLM responses use structured output (`output_config` with `json_schema`) to constrain
responses to `{"reasoning": "...", "code": "..."}` JSON objects. This eliminates regex-based
code extraction and provides clean separation of reasoning from executable code. Feedback
messages after eval are also structured JSON.

Default models:
- Large: `claude-sonnet-4-5-20250929`
- Small: `claude-haiku-4-5-20251001`

## Module Map

### RLM Engine

| Module | Purpose |
|---|---|
| `RLM` | Public API: `run/3`, `start_session/1`, `send_message/3`, `history/1`, `status/1` |
| `RLM.Config` | Config struct; loads from app env + keyword overrides |
| `RLM.Worker` | GenServer per execution node; iterate loop + keep_alive mode |
| `RLM.Eval` | Sandboxed `Code.eval_string` with async IO capture + cwd injection |
| `RLM.Sandbox` | Functions injected into eval'd code (helpers + LLM calls + tool wrappers) |
| `RLM.LLM` | Anthropic Messages API client with structured output (`extract_structured/1`) |
| `RLM.Prompt` | System prompt loading + structured JSON feedback message formatting |
| `RLM.Helpers` | `chunks/2`, `grep/2`, `preview/2`, `list_bindings/0` |
| `RLM.Truncate` | Head+tail string truncation for stdout overflow |
| `RLM.Span` | Span/run ID generation |
| `RLM.IEx` | IEx convenience helpers: `start/1`, `chat/2`, `start_chat/2`, `watch/2` |
| `RLM.EventLog` | Per-run Agent storing structured reasoning trace |
| `RLM.EventLog.Sweeper` | GenServer; periodically GCs stale EventLog agents + :dets TTL sweep |
| `RLM.TraceStore` | GenServer owning `:dets` table; persists events across restarts |
| `RLM.Telemetry` | Handler attachment GenServer |
| `RLM.Telemetry.Logger` | Structured logging handler |
| `RLM.Telemetry.PubSub` | Phoenix.PubSub broadcast handler |
| `RLM.Telemetry.EventLogHandler` | Routes telemetry events to EventLog Agent AND TraceStore |

### Filesystem Tools

| Module | Purpose |
|---|---|
| `RLM.Tool` | `@behaviour` with `name/0`, `description/0`, `execute/1` callbacks |
| `RLM.ToolRegistry` | Central dispatch; `all/0`, `names/0`, `descriptions/0`, `execute/2` |
| `RLM.Tools.ReadFile` | Read file contents (≤ 100 KB) |
| `RLM.Tools.WriteFile` | Write or overwrite a file (creates parents) |
| `RLM.Tools.EditFile` | Exact-string replacement (uniqueness-guarded) |
| `RLM.Tools.Bash` | Shell commands via `Task.yield` timeout guard |
| `RLM.Tools.Grep` | ripgrep search with glob filtering |
| `RLM.Tools.Glob` | Find files by pattern |
| `RLM.Tools.Ls` | List directory with sizes |

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

## Testing Conventions

- Tests use `RLM.Test.MockLLM` (global ETS-based response queue) for deterministic testing
- Worker/keep_alive tests run `async: false` since MockLLM uses global state
- Tool tests and sandbox tests can run `async: true` (no global state)
- Live API tests tagged with `@moduletag :live_api` and excluded by default
- `mix test --include live_api` requires `CLAUDE_API_KEY` env var
- Test support files in `apps/rlm/test/support/`
- Tool tests use a per-test temp directory (created in `setup`, cleaned in `on_exit`)
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
