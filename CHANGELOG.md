# Changelog

All notable changes to this project are documented here.

---

## [Unreleased]

### Changed

**Structured output for LLM responses and feedback messages**

- LLM responses now use Claude structured output (`output_config` with JSON schema)
  constraining responses to `{"reasoning": "...", "code": "..."}` objects. This
  eliminates regex-based code extraction (`extract_code/1`) from the main iterate
  loop, removing an entire class of `:no_code_block` retry failures.
- `RLM.LLM.extract_structured/1` added to parse structured JSON responses; returns
  `{:ok, %{reasoning: ..., code: ...}}` or `{:error, reason}`
- `RLM.LLM.response_schema/0` exposes the JSON schema used for constrained decoding
- Feedback messages after eval are now structured JSON with `eval_status`, `stdout`/
  `error_output`, `bindings` summary, and `final_answer_set` flag — replacing the
  previous plain-text markdown format
- `RLM.Prompt.build_feedback_message/4` replaces the old 2-arity version; accepts
  bindings info and final_answer_set boolean for accurate trace recording
- `RLM.Prompt.build_empty_code_feedback/0` added for when the LLM returns empty code
- `RLM.Prompt.build_nudge_message/0` now returns structured JSON
- `RLM.Worker` telemetry metadata now includes `reasoning_preview` and `code_present`
  fields (replacing `code_extracted`)
- System prompt (`priv/system_prompt.md`) updated to document JSON response format
  and structured feedback fields
- `RLM.LLM.extract_code/1` retained for backward compatibility but no longer used
  in the main iterate loop
- `RLM.Test.MockLLM.mock_response/1,2` helper added for building JSON mock responses

**Documentation consolidation**

- Replaced `GUIDE.html` with a comprehensive 12-section reference covering the
  current unified architecture: OTP supervision tree, iterate loop deep-dive,
  interactive sessions, tool system, telemetry pipeline, tracing/persistence,
  LiveView dashboard, full config reference, and module map for all ~34 modules
- Replaced `REVIEW.html` with an updated system review and OTP assessment (8/10):
  three-tier analysis (idiomatic / passable / non-idiomatic), naming proposals,
  gaps & missing features, Python RLM comparison, architectural do/don't
  recommendations, testing assessment, and prioritised future directions
- Deleted `design_guide.html` — completely outdated (pre-dated dashboard and
  agent consolidation); content subsumed by new GUIDE
- Deleted `SPEC.md` — referenced deleted `RLM.Agent.*` namespace throughout;
  phased implementation plan is complete

### Added

**Consolidated Agent into RLM Engine — unified architecture**

- `RLM.Tool` behaviour — lightweight tool contract with `name/0`, `description/0`, `execute/1`
- `RLM.Tools.*` — 7 filesystem tools (ReadFile, WriteFile, EditFile, Bash, Grep, Glob, Ls)
  ported from the former `RLM.Agent.Tools.*` namespace
- `RLM.ToolRegistry` — central tool dispatch with `all/0`, `names/0`, `descriptions/0`,
  `execute/2`, `description_for/1`
- `RLM.Sandbox` tool wrappers — `read_file/1`, `write_file/2`, `edit_file/3`, `bash/1-2`,
  `rg/1-3`, `find_files/1-2`, `ls/0-1`, `list_tools/0`, `tool_help/1` available inside
  eval'd code. Paths resolve relative to session working directory.
- `RLM.Worker` keep-alive mode — `keep_alive: true` starts the Worker in `:idle` state,
  accepting `send_message` calls. Bindings persist across turns; `final_answer` and iteration
  count reset per turn. Emits `[:rlm, :turn, :complete]` instead of `[:rlm, :node, :stop]`.
- `RLM.start_session/1` — start an interactive keep-alive session, returns `{:ok, session_id}`
- `RLM.send_message/3` — send a message to a keep-alive session, returns `{:ok, answer}`
- `RLM.history/1`, `RLM.status/1` — introspect session state
- `RLM.IEx` — IEx convenience helpers (`start/1`, `chat/2-3`, `start_chat/2`, `watch/2`,
  `history/1`, `status/1`) replacing the former `RLM.Agent.IEx`
- `[:rlm, :turn, :complete]` telemetry event for keep-alive turn completion
- `cwd` injection into `RLM.Eval` via `Process.put(:rlm_cwd, ...)` for tool path resolution

### Changed

- `RLM.Worker` gains `:keep_alive`, `:cwd`, `:pending_from` struct fields
- Worker's `start_async_eval` passes `cwd` to `RLM.Eval.run/3`
- `RLM.Eval.run/3` injects `:rlm_cwd` into the eval process dictionary

### Removed

- Entire `RLM.Agent.*` namespace (15 source files, 3 test files):
  `Session`, `LLM`, `Message`, `Tool`, `ToolRegistry`, `Prompt`, `IEx`,
  and all `RLM.Agent.Tools.*` modules including `RlmQuery`
- `RLM.AgentSup` DynamicSupervisor removed from supervision tree
- `agent_llm_module` config field removed from `RLM.Config`
- SSE streaming (was in `RLM.Agent.LLM`; can be re-added to `RLM.LLM` if needed)

---

### Added

**RLM Live Trace Dashboard — :dets persistence + Phoenix LiveView**

- `RLM.TraceStore` — new GenServer that owns a `:dets` `:bag` table (`priv/traces.dets`).
  Provides `put_event/2`, `get_events/1`, `list_run_ids/0`, `delete_older_than/1`.
  Events survive server restarts without any additional dependencies.
- Write-through telemetry: `RLM.Telemetry.EventLogHandler` now writes every event to
  both the in-memory `EventLog` Agent (hot path) and `TraceStore` (persistence).
- `RLM.EventLog.Sweeper` now calls `RLM.TraceStore.delete_older_than/1` on each sweep
  cycle, enforcing the same TTL policy across both stores.
- `RLM.EventLog.get_events_from_store/1` — convenience delegate to `TraceStore` for
  querying completed runs after their Agent has been swept.
- New umbrella app `apps/rlm_web` — Phoenix 1.8 LiveView dashboard (read-only):
  - `GET /` (`RunListLive`) — live table of all runs loaded from TraceStore; new rows
    appear in < 1 s via PubSub `rlm:runs` subscription.
  - `GET /runs/:run_id` (`RunDetailLive`) — recursive span tree with status badges,
    context size, timing, and per-iteration expandable code/stdout/bindings panels.
    Falls back to TraceStore when the in-memory Agent has been swept.
  - `RlmWebWeb.TraceComponents` — `span_node/1` and `iteration_card/1` HEEx components.
  - Reuses `RLM.PubSub` — no extra PubSub process started.

### Fixed

- `priv/system_prompt.md` — added **Elixir Syntax Rules** section addressing
  two recurring LLM code-generation failures observed during live testing:
  - Regex sigil delimiter: models (especially haiku) emit `~r\b...\b/i` using
    `\` as the delimiter; correct form is `~r/\b...\b/i`.
  - Heredoc syntax: models place content on the same line as the opening `"""`;
    Elixir requires an immediate newline after the opening triple-quote.
  - Sub-call result unwrapping: documented that `lm_query`/`parallel_query`
    return `{:ok, result} | {:error, reason}` tuples.

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
