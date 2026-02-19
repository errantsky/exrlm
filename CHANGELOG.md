# Changelog

All notable changes to this project are documented here.

---

## [Unreleased]

### Added

- `priv/soul.md` — identity and behavioural guidelines file loaded into the coding agent
  as the opening section of its system prompt. Defines tone, priorities, and boundaries
  for the agent's persona. `RLM.Agent.Prompt.build/1` now prepends this content via a
  private `soul/0` helper that reads the file at runtime and falls back to an empty
  string if the file is absent.

---

## [0.2.0] — 2026-02-19

### Added

**RLM Engine — foundation hardening**

- `RLM.run/3` now returns `{:ok, answer, run_id}` (3-tuple). The `run_id` can be
  passed to `RLM.EventLog` to retrieve the full execution trace.
- `Process.monitor` on the spawned Worker: crashes surface as `{:error, "Worker crashed: ..."}` instead of hanging indefinitely. A configurable overall timeout
  (`eval_timeout * 2`) sends `{:error, "RLM.run timed out after ...ms"}` and
  terminates the worker.
- `max_concurrent_subcalls` config field (default: 10). `handle_call({:spawn_subcall})`
  now enforces both depth and concurrency limits via a `cond` branch.
- `RLM.EventLog.get_started_at/1` — exposes the `started_at` monotonic timestamp
  stored in each trace Agent.
- `RLM.EventLog.Sweeper` — a GenServer that periodically scans `RLM.EventStore` and
  terminates stale EventLog agents (default TTL: 1 hour, sweep interval: 5 minutes).
  Prevents unbounded memory growth in long-running systems.
- `{Task.Supervisor, name: RLM.TaskSupervisor}` added to supervision tree (used by
  the bash tool and agent session tasks).

**Coding Agent — new subsystem**

- `RLM.Agent.LLM` — Anthropic Messages API client with native `tool_use` support and
  SSE response parsing. `on_chunk` callbacks deliver text deltas during parsing.
- `RLM.Agent.Message` — constructors and API serialisation helpers for the multi-turn
  message format (`user/1`, `assistant/1`, `tool_result/3`, `tool_results/1`, etc.).
- `RLM.Agent.Session` — GenServer driving the tool-use loop. Spawns each turn as a
  `Task.Supervisor` child so the GenServer mailbox stays responsive. Broadcasts
  `{:agent_event, type, payload}` events to `"agent:session:<id>"` on `RLM.PubSub`.
- `RLM.Agent.Prompt` — composable system prompt builder (`build/1` with `:cwd` and
  `:extra` options).
- `RLM.Agent.Tool` — `@behaviour` with `spec/0` (JSON schema) and `execute/1` callbacks.
- `RLM.Agent.ToolRegistry` — central dispatch; `specs/0`, `execute/2`, `spec_for/1`.
- `RLM.Agent.IEx` — IEx helpers: `start/1`, `chat/3`, `start_chat/2`, `watch/2`,
  `history/1`, `status/1`.
- 8 tool implementations: `ReadFile`, `WriteFile`, `EditFile`, `Bash`, `Grep`, `Glob`,
  `Ls`, `RlmQuery` (the bridge tool that delegates from agent to RLM engine).
- `DynamicSupervisor (RLM.AgentSup)` added to supervision tree.
- `bash` tool uses `Task.async` + `Task.yield/2` for timeout enforcement (`System.cmd`
  has no `:timeout` option).

**Tests**

- `RLM.WorkerTest` — covers `max_depth` and `max_concurrent_subcalls` enforcement,
  and the `{:ok, answer, run_id}` return shape.
- `RLM.Agent.LLMTest` — unit tests for `Message` helpers; live API tests for sync,
  tool-call, and streaming paths.
- `RLM.Agent.ToolTest` — unit tests for all 8 tools and `ToolRegistry`.
- `RLM.Agent.SessionTest` — tests the full tool-use GenServer loop with mock tools.
- All existing integration tests updated for the new 3-tuple return value.

### Changed

- `RLM.Worker.handle_call({:spawn_subcall})` refactored from `if/else` to `cond` to
  add the `max_concurrent_subcalls` check alongside the existing depth check.

### Fixed

- SSE streaming: Req 0.5's `into:` option (both `fn` and `:self` forms) conflicts with
  Finch's adapter return contract. Switched to buffering the full SSE response body as
  a binary and parsing `data:` lines synchronously. Anthropic closes the connection
  after `message_stop`, so this is non-blocking in practice.

---

## [0.1.0] — 2026-02-18

### Added

Initial implementation of the RLM (Recursive Language Model) engine:

- `RLM` public API (`run/3`, `run_async/3`)
- `RLM.Worker` GenServer with the async-eval iterate loop
- `RLM.Eval` — sandboxed `Code.eval_string` with IO capture
- `RLM.Sandbox` — `lm_query/2`, `chunks/2`, `grep/2`, `preview/2`, `list_bindings/0`
- `RLM.LLM` — Anthropic Messages API client with code-block extraction
- `RLM.Prompt` — system prompt loading from `priv/system_prompt.md`
- `RLM.Helpers` and `RLM.Truncate` — data-processing utilities
- `RLM.EventLog` — per-run Agent storing structured reasoning trace
- `RLM.Telemetry` — 14 telemetry events with Logger and PubSub handlers
- `RLM.Config` — config struct with app-env + keyword override loading
- `RLM.Span` — span/run ID generation
- Full OTP supervision tree under `RLM.Supervisor`
- Integration test suite with `RLM.Test.MockLLM` (ETS-based)
- Architecture review (HTML) and coding agent specification (Markdown)
