# CLAUDE.md — RLM (Recursive Language Model) Engine

## Project Structure

This is an Elixir umbrella project at `rlm_umbrella/`.

```
rlm_umbrella/
├── apps/
│   └── rlm/              # Core engine (no web framework)
│       ├── lib/rlm/       # Source modules
│       ├── test/           # Tests
│       └── priv/           # Runtime assets (system_prompt.md)
├── config/
│   └── config.exs         # App-wide configuration
└── mix.exs                # Umbrella root
```

## Build & Run

```bash
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
├── Registry (RLM.Registry)
├── Phoenix.PubSub (RLM.PubSub)
├── DynamicSupervisor (RLM.WorkerSup) — Workers are :temporary
├── DynamicSupervisor (RLM.EventStore) — EventLog Agents
└── RLM.Telemetry (GenServer)
```

### LLM Client
Uses the Anthropic Messages API (not OpenAI format). System messages are extracted
and sent as the top-level `system` field. Requires `CLAUDE_API_KEY` env var.

Default models:
- Large: `claude-sonnet-4-5-20250929`
- Small: `claude-haiku-4-5-20251001`

## Module Map

| Module | Purpose |
|---|---|
| `RLM` | Public API: `run/3`, `run_async/3` |
| `RLM.Config` | Config struct, loads from app env + overrides |
| `RLM.Worker` | GenServer per execution node, iterate loop |
| `RLM.Eval` | Sandboxed `Code.eval_string` with IO capture |
| `RLM.Sandbox` | Functions available inside eval'd code (`lm_query`, `chunks`, etc.) |
| `RLM.LLM` | Anthropic Messages API client + code extraction |
| `RLM.Prompt` | System prompt loading and message formatting |
| `RLM.Helpers` | `chunks`, `grep`, `preview`, `list_bindings` |
| `RLM.Truncate` | Head+tail string truncation |
| `RLM.Span` | Span/run ID generation |
| `RLM.EventLog` | Per-run Agent storing structured reasoning trace |
| `RLM.Telemetry` | Handler attachment GenServer |
| `RLM.Telemetry.Logger` | Structured logging handler |
| `RLM.Telemetry.PubSub` | Phoenix.PubSub broadcast handler |
| `RLM.Telemetry.EventLogHandler` | Routes events to EventLog Agent |

## Testing Conventions

- Tests use `RLM.Test.MockLLM` (global ETS-based response queue) for deterministic testing
- All tests run `async: false` since MockLLM uses global state
- Live API tests tagged with `@moduletag :live_api` and excluded by default
- Test support files in `apps/rlm/test/support/`

## Important Notes

- `Code.eval_string` usage in `RLM.Eval` is intentional — it's the core REPL mechanism
- Workers use `restart: :temporary` — they terminate normally after completion
- The `llm_module` config field enables dependency injection for testing
- `.env` file with `CLAUDE_API_KEY` should exist but never be committed
