# exrlm (RLM) vs OpenAI Symphony — Comparison

## What They Are

| | **exrlm (RLM)** | **OpenAI Symphony** |
|---|---|---|
| **Core idea** | Recursive coding agent — an LLM writes Elixir code that runs in a persistent REPL, with outputs fed back to drive the next iteration. Eval'd code can spawn child LLM workers recursively. | Autonomous issue-tracker daemon — polls Linear for work items, creates isolated workspaces per issue, launches Codex agents to implement them, and manages the full lifecycle until done. |
| **Metaphor** | A single engineer with a REPL who can delegate sub-tasks to junior engineers | A project manager who assigns tickets to autonomous developers and tracks their progress |
| **Language** | Elixir / Phoenix 1.8 / OTP 27 | Elixir / OTP (reference implementation); spec is language-agnostic |
| **License** | Private / personal project | Apache 2.0 |
| **Maturity** | v0.3.0, personal learning project | "Engineering preview for testing in trusted environments" |

## Architectural Philosophy

**exrlm** is **computation-focused**: the core primitive is an LLM-driven REPL loop. The LLM reasons, writes code, the code executes, results flow back. The "recursive" innovation is that eval'd code can spawn child LLM workers — enabling map-reduce, parallel delegation, and hierarchical decomposition of problems. Everything happens within a single Elixir application.

**Symphony** is **workflow-focused**: the core primitive is an issue-to-PR pipeline. It bridges an issue tracker (Linear) to a coding agent (Codex) through orchestration — workspace setup, prompt rendering, session management, retry logic, and lifecycle tracking. Symphony doesn't implement the agent itself; it manages agents.

## Key Differences

### 1. Agent vs Orchestrator

| Aspect | **exrlm** | **Symphony** |
|---|---|---|
| Does the LLM reasoning? | Yes — RLM *is* the agent | No — Symphony delegates to Codex |
| Recursive sub-agents? | Yes — eval'd code spawns child Workers with their own REPL loops, up to depth 5 | No — one Codex session per issue; continuation turns on the same thread |
| Code execution model | `Code.eval_string` in a persistent REPL with bindings that carry across iterations | Codex runs in an isolated workspace filesystem; Symphony doesn't eval anything itself |

### 2. Work Discovery

| Aspect | **exrlm** | **Symphony** |
|---|---|---|
| Input | Programmatic: `RLM.run(context, query)` or interactive session `send_message/3` | Automated: polls Linear every 30s for issues in active states |
| Trigger | Developer calls the API | Daemon continuously monitors issue tracker |
| Scope | Single task at a time (though workers parallelize internally) | Up to 10 concurrent issues, each with its own workspace and Codex session |

### 3. LLM Integration

| Aspect | **exrlm** | **Symphony** |
|---|---|---|
| LLM provider | Anthropic (Claude) | OpenAI (Codex app-server over stdio JSON-RPC) |
| Communication | Direct HTTP to Anthropic Messages API | stdio protocol with Codex subprocess |
| Structured output | `json_schema` output_config for `{reasoning, code}` | Prompts rendered from WORKFLOW.md templates |
| Schema-mode queries | Yes — `lm_query(text, schema: json_schema)` for single-call structured extraction | No direct equivalent |
| Context management | Automatic history compaction when nearing 80% of context window | Thread-based; continuation turns use brief guidance instead of full prompt replay |

### 4. Supervision & Process Model

Both leverage OTP, but for very different things:

| Aspect | **exrlm** | **Symphony** |
|---|---|---|
| Why OTP? | Each run spawns a `Run` GenServer → `DynamicSupervisor` of Workers → `Task.Supervisor` for eval tasks. OTP manages the recursive worker tree. | The Orchestrator is the single scheduling authority. Workers are per-issue processes. OTP supervises long-running daemon lifecycle. |
| Concurrency model | Workers are flat siblings in a DynSup; parent-child tree tracked in ETS; crash propagation is manual via monitors | One worker process per issue; concurrency controlled by `max_concurrent_agents` config |
| Deadlock prevention | Critical — eval runs as `Task.Supervisor.async_nolink` so Worker mailbox stays free for `{:spawn_subcall, ...}` calls from eval'd code | Not a concern — Symphony doesn't execute code that calls back into itself |

### 5. Workspace & Isolation

| Aspect | **exrlm** | **Symphony** |
|---|---|---|
| Isolation unit | Per-run: Worker state, bindings, history are all in-process | Per-issue: dedicated filesystem directory with git clone, hooks, and lifecycle management |
| Filesystem tools | 7 tools (read, write, edit, bash, grep, glob, ls) exposed in the REPL sandbox | Delegated entirely to Codex; Symphony just manages the workspace directory |
| Safety invariants | Raw data never enters LLM context; stdout truncated (head+tail 4000 chars each) | Workspace path containment (absolute normalization, root prefix check); directory name sanitization |

### 6. Retry & Error Handling

| Aspect | **exrlm** | **Symphony** |
|---|---|---|
| On failure | Worker terminates; `Process.monitor` surfaces crash as `{:error, reason}` | Exponential backoff retry: 10s → 20s → 40s → ... → 5min cap |
| Continuation | No automatic retry; developer decides | Automatic continuation retries (1s delay) after successful turns to check if issue remains active |
| Stall detection | Nudging: if last 3 code submissions are >85% similar (Jaccard), inject a nudge message | Kill session if no Codex event for 5 minutes |

### 7. Observability

| Aspect | **exrlm** | **Symphony** |
|---|---|---|
| Web UI | Phoenix LiveView dashboard at `:4000` — run list + recursive span tree with expandable iterations | Optional HTTP dashboard + JSON API (`/api/v1/state`, per-issue debug) |
| Tracing | 17 telemetry events, EventLog Agent per run, `:dets` persistence via TraceStore | Structured logging with `issue_id`/`session_id` context fields; token tracking from Codex events |
| Persistence | `:dets` table with TTL sweep | None required — stateless restart recovery via re-polling |

### 8. Configuration

| Aspect | **exrlm** | **Symphony** |
|---|---|---|
| Config source | Elixir app env + keyword overrides via `RLM.Config` struct | `WORKFLOW.md` with YAML front matter + Markdown prompt template |
| Hot reload | No | Yes — watches WORKFLOW.md for changes, applies to future dispatches |
| Dynamic values | Static per-run | `$VAR_NAME` env indirection, `~` expansion, runtime re-validation |

## What exrlm Has That Symphony Doesn't

1. **Recursive LLM execution** — The core differentiator. Code produced by one LLM call can spawn child LLM workers, enabling hierarchical problem decomposition and map-reduce patterns. Symphony uses a flat one-agent-per-issue model.

2. **Persistent REPL with bindings** — Variables survive across iterations and across conversation turns in session mode. This is a fundamentally different execution model from "run a coding agent in a directory."

3. **Schema-mode direct queries** — `lm_query(text, schema: ...)` makes a single LLM call with a JSON schema constraint and returns a parsed map. No child Worker, no system prompt, no iterate loop. A lightweight structured extraction primitive.

4. **Three invariants on data flow** — Raw data never enters the LLM context (only preview/metadata); sub-LLM outputs stay in variables (never shown to parent); stdout is always truncated. These are architectural constraints, not just best practices.

5. **History compaction** — Automatic context window management: when estimated tokens exceed 80% capacity, history is collapsed into a binding and conversation restarted.

6. **Interactive session mode** — `start_session/1` + `send_message/3` for multi-turn conversations with persistent state. Symphony is purely autonomous (no human-in-the-loop during execution).

## What Symphony Has That exrlm Doesn't

1. **Issue tracker integration** — Native Linear GraphQL client with candidate fetching, state reconciliation, blocker detection, and priority-based dispatch. exrlm has no concept of where work comes from.

2. **Autonomous daemon operation** — Symphony runs continuously, polling for work, dispatching agents, and managing retries without human intervention. exrlm requires explicit API calls.

3. **Multi-issue concurrency** — Up to 10 independent issues running simultaneously with per-state concurrency limits. exrlm handles one task at a time (though with internal parallelism via sub-workers).

4. **Workspace lifecycle management** — Full directory lifecycle: creation, git clone via hooks, per-run hooks (`before_run`, `after_run`), cleanup on terminal state. exrlm has no workspace abstraction.

5. **Exponential backoff retries** — Sophisticated retry strategy with continuation retries (1s for success) and failure-driven retries (exponential up to 5min). exrlm doesn't retry.

6. **Dynamic configuration reload** — Hot-reload of `WORKFLOW.md` without restart. Changes to polling intervals, concurrency limits, hooks, and prompts apply immediately.

7. **Dispatch eligibility logic** — Blocker detection (don't dispatch if upstream issues are open), priority sorting, per-state concurrency limits, preflight validation. exrlm has no scheduling intelligence.

8. **Agent-agnostic design** — Symphony's spec is language-agnostic and agent-agnostic (currently Codex, but the stdio protocol could work with any agent). exrlm is tightly coupled to Anthropic's API.

## Where They Overlap

- Both are written in Elixir and leverage OTP supervision trees
- Both have web dashboards (Phoenix LiveView / HTTP API)
- Both use `:temporary` workers that terminate after completion
- Both have structured observability (telemetry/logging)
- Both enforce filesystem safety (path validation, containment)
- Both are experimental/preview-stage projects

## Complementary, Not Competing

These projects occupy different layers of the agent stack:

```
┌─────────────────────────────────────────────┐
│  Symphony (Orchestration Layer)              │
│  "Which issues need work? Dispatch agents."  │
├─────────────────────────────────────────────┤
│  exrlm / Codex (Agent Layer)                │
│  "Given a task, reason + write + execute    │
│   code until solved."                        │
└─────────────────────────────────────────────┘
```

In theory, Symphony could orchestrate exrlm as its agent backend (replacing Codex) if exrlm exposed an app-server stdio protocol. Conversely, exrlm could benefit from Symphony-style features: issue tracker integration, autonomous dispatch, retry strategies, and workspace lifecycle management.

The most interesting architectural contrast is **recursive decomposition** (exrlm) vs **flat orchestration** (Symphony). exrlm lets a single agent break problems into sub-problems dynamically at runtime. Symphony breaks problems at the issue-tracker level — one issue, one agent, no runtime decomposition.
