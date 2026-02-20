# Migration Plan: Consolidate Agent into RLM Engine

## Goal

Remove the `RLM.Agent.*` namespace entirely. Merge its capabilities (file I/O,
bash, grep, glob, ls, multi-turn conversation, IEx helpers) into the RLM engine
by expanding `RLM.Sandbox`, `RLM.Worker`, and the system prompt.

---

## Phase 1 — Tool Modules (`RLM.Tools.*`)

Create a new `RLM.Tools` namespace with a lightweight behaviour for documentation
and discoverability. These are **not** Anthropic tool_use specs — they are plain
Elixir modules with `name/0`, `doc/0`, and `execute/N`.

### 1.1 Create `RLM.Tool` behaviour

**New file:** `lib/rlm/tool.ex`

```elixir
defmodule RLM.Tool do
  @callback name() :: atom()
  @callback doc() :: String.t()
end
```

No `execute` callback in the behaviour — arities differ per tool. The behaviour
exists solely so `list_tools/0` and `tool_help/1` can introspect at runtime.

### 1.2 Create tool modules

Port each `RLM.Agent.Tools.*` implementation into `RLM.Tools.*`. The logic stays
identical but the interface changes from `execute(%{"key" => val})` to normal
function signatures.

| New module | Source | Function signature |
|---|---|---|
| `RLM.Tools.ReadFile` | `Agent.Tools.ReadFile` | `execute(path)` |
| `RLM.Tools.WriteFile` | `Agent.Tools.WriteFile` | `execute(path, content)` |
| `RLM.Tools.EditFile` | `Agent.Tools.EditFile` | `execute(path, old_string, new_string)` |
| `RLM.Tools.Bash` | `Agent.Tools.Bash` | `execute(command, opts \\ [])` |
| `RLM.Tools.Grep` | `Agent.Tools.Grep` | `execute(pattern, opts \\ [])` |
| `RLM.Tools.Glob` | `Agent.Tools.Glob` | `execute(pattern, opts \\ [])` |
| `RLM.Tools.Ls` | `Agent.Tools.Ls` | `execute(path \\ ".")` |

**New files:** `lib/rlm/tools/` directory with 7 modules.

Each module `@behaviour RLM.Tool` and implements `name/0` and `doc/0`. The `doc/0`
returns a string showing the sandbox function signature, description, and examples
— this is what `tool_help(:read_file)` will display to the LLM.

### 1.3 Create `RLM.Tools.Registry`

**New file:** `lib/rlm/tools/registry.ex`

A simple module with a `@tools` list. Provides:
- `all/0` — list of tool modules
- `list/0` — `[{name, one_line_summary}]` for `list_tools/0`
- `doc/1` — full doc string for `tool_help/1`

---

## Phase 2 — Expand `RLM.Sandbox`

### 2.1 Add tool wrapper functions

Add public functions to `RLM.Sandbox` that delegate to `RLM.Tools.*` and unwrap
results. Errors raise so the LLM's code reads naturally (`content = read_file(path)`
rather than `{:ok, content} = read_file(path)`).

```elixir
def read_file(path), do: unwrap!(RLM.Tools.ReadFile.execute(path))
def write_file(path, content), do: unwrap!(RLM.Tools.WriteFile.execute(path, content))
def edit_file(path, old, new), do: unwrap!(RLM.Tools.EditFile.execute(path, old, new))
def bash(command, opts \\ []), do: unwrap!(RLM.Tools.Bash.execute(command, opts))
def grep_files(pattern, opts \\ []), do: unwrap!(RLM.Tools.Grep.execute(pattern, opts))
def glob(pattern, opts \\ []), do: unwrap!(RLM.Tools.Glob.execute(pattern, opts))
def ls(path \\ "."), do: unwrap!(RLM.Tools.Ls.execute(path))

def list_tools, do: RLM.Tools.Registry.list()
def tool_help(name), do: RLM.Tools.Registry.doc(name)

defp unwrap!({:ok, value}), do: value
defp unwrap!({:error, msg}), do: raise(msg)
```

**Modified file:** `lib/rlm/sandbox.ex`

Note: the existing `grep/2` searches within a string (in-memory). The new
`grep_files/2` searches files on disk via ripgrep. Both stay; different names,
different purposes.

### 2.2 Inject working directory into process dictionary

**Modified file:** `lib/rlm/eval.ex`

Add `Process.put(:rlm_cwd, cwd)` alongside the existing `worker_pid` and
`bindings_info` injections. The `cwd` value comes from a new option in
`RLM.Eval.run/3` and flows from `RLM.Worker` init opts or defaults to
`File.cwd!()`.

`RLM.Tools.Bash` reads `Process.get(:rlm_cwd)` as the default working directory.

---

## Phase 3 — Multi-turn Worker

### 3.1 Modify `RLM.Worker.complete/2`

**Modified file:** `lib/rlm/worker.ex`

Change `complete/2` so it doesn't always stop the process. Add a `keep_alive`
config option (default: `false` for backward compat). When `keep_alive: true`:

- After `final_answer` is set, reply to the caller but transition to `:idle`
  instead of `{:stop, :normal, ...}`
- Reset `final_answer` to `nil` in bindings
- Keep all other bindings, history, and state intact

When `keep_alive: false` (default): current behaviour, `{:stop, :normal, ...}`.

### 3.2 Add `handle_call({:send_message, text}, ...)`

**Modified file:** `lib/rlm/worker.ex`

New `handle_call` clause that:
- Accepts a user message when status is `:idle`
- Appends a user message to history
- Resets `final_answer` to `nil` in bindings
- Sets status to `:running` and stores `from` for later reply
- Sends `:iterate` to self
- Returns `{:noreply, state}` (reply comes when `final_answer` is set)

Reject with `{:error, "Worker is busy"}` when status is `:running`.

### 3.3 Modify `RLM.run/3` to support reuse

**Modified file:** `lib/rlm.ex`

Add `RLM.send_message/2` that sends a follow-up message to an existing Worker
by span_id. The existing `RLM.run/3` stays unchanged (one-shot mode).

---

## Phase 4 — IEx Helpers

### 4.1 Rewrite `RLM.Agent.IEx` → `RLM.IEx`

**New file:** `lib/rlm/iex.ex` (replaces `lib/rlm/agent/iex.ex`)

- `start/1` — starts a Worker with `keep_alive: true` via `RLM.WorkerSup`,
  returns `span_id`
- `chat/3` — calls `RLM.send_message(span_id, text)`, prints result
- `start_chat/2` — `start/1` + initial `RLM.run` with the first query
- `watch/2` — subscribes to PubSub topic for telemetry events (see Phase 5)
- `history/1` — calls Worker for message history (new `handle_call(:history, ...)`)
- `status/1` — calls Worker for stats (new `handle_call(:status, ...)`)

### 4.2 Add `handle_call(:history, ...)` and `handle_call(:status, ...)` to Worker

**Modified file:** `lib/rlm/worker.ex`

Simple reads from GenServer state — return `state.history` and a stats map.

---

## Phase 5 — PubSub Events on Worker

### 5.1 Add PubSub broadcasts to Worker

**Modified file:** `lib/rlm/worker.ex`

At the same points where telemetry events already fire, also broadcast via
`Phoenix.PubSub` on topic `"rlm:worker:<span_id>"`. Events mirror the existing
telemetry events:

- `:iteration_start` — before LLM call
- `:iteration_stop` — after eval completes (includes code, stdout, final_answer)
- `:subcall_spawn` / `:subcall_result`
- `:complete` — when final_answer is set

This enables the `watch/1` IEx helper and future LiveView integration.

---

## Phase 6 — System Prompt

### 6.1 Expand `priv/system_prompt.md`

**Modified file:** `apps/rlm/priv/system_prompt.md`

Add a new section documenting the file/shell/search tools. Keep the existing
sections unchanged. New section:

```markdown
## File and Shell Tools
- `read_file(path)` — read file contents (max 100KB, truncated with notice)
- `write_file(path, content)` — write/overwrite a file (creates parent dirs)
- `edit_file(path, old_string, new_string)` — exact string replacement (must be unique)
- `bash(command, opts \\ [])` — run shell command. opts: :timeout_ms, :cwd
- `grep_files(pattern, opts \\ [])` — search files with ripgrep. opts: :path, :glob, :case_insensitive
- `glob(pattern, opts \\ [])` — find files by glob pattern. opts: :base
- `ls(path \\ ".")` — list directory contents with sizes

## Tool Discovery
- `list_tools()` — show all available tools with one-line descriptions
- `tool_help(:name)` — show detailed usage, options, and examples for a tool

## Error Handling
Tool errors raise exceptions. The REPL catches them and shows you the error.
Read the message, fix your code, and try again.
```

### 6.2 Update `RLM.Prompt.default_system_prompt/0`

**Modified file:** `lib/rlm/prompt.ex`

Update the inline fallback prompt to match the expanded `priv/system_prompt.md`.

---

## Phase 7 — Config Cleanup

### 7.1 Remove `agent_llm_module` from `RLM.Config`

**Modified file:** `lib/rlm/config.ex`

Remove the `agent_llm_module` field from the Config struct and `load/1`.

### 7.2 Remove `RLM.AgentSup` from supervision tree

**Modified file:** `lib/rlm/application.ex`

Delete the line:
```elixir
{DynamicSupervisor, name: RLM.AgentSup, strategy: :one_for_one},
```

---

## Phase 8 — Delete Agent Modules

### Files to delete

```
lib/rlm/agent/llm.ex              # RLM.Agent.LLM (327 LOC)
lib/rlm/agent/message.ex           # RLM.Agent.Message (119 LOC)
lib/rlm/agent/session.ex           # RLM.Agent.Session (302 LOC)
lib/rlm/agent/prompt.ex            # RLM.Agent.Prompt (68 LOC)
lib/rlm/agent/tool.ex              # RLM.Agent.Tool (57 LOC)
lib/rlm/agent/tool_registry.ex     # RLM.Agent.ToolRegistry (59 LOC)
lib/rlm/agent/iex.ex               # RLM.Agent.IEx (195 LOC)
lib/rlm/agent/tools/read_file.ex   # (43 LOC)
lib/rlm/agent/tools/write_file.ex  # (38 LOC)
lib/rlm/agent/tools/edit_file.ex   # (74 LOC)
lib/rlm/agent/tools/bash.ex        # (73 LOC)
lib/rlm/agent/tools/grep.ex        # (98 LOC)
lib/rlm/agent/tools/glob.ex        # (50 LOC)
lib/rlm/agent/tools/ls.ex          # (51 LOC)
lib/rlm/agent/tools/rlm_query.ex   # (68 LOC)
```

Delete the empty `lib/rlm/agent/` and `lib/rlm/agent/tools/` directories.

---

## Phase 9 — Tests

### 9.1 Tests to delete

```
test/rlm/agent/llm_test.exs       # Tests Agent.LLM + Agent.Message
test/rlm/agent/session_test.exs   # Tests Agent.Session + Agent.Prompt + MockAgentLLM
test/rlm/agent/tool_test.exs      # Tests Agent.ToolRegistry + all Agent.Tools.*
```

Delete the empty `test/rlm/agent/` directory.

### 9.2 Tests to create

**New file:** `test/rlm/tools_test.exs`

Port the tool-level tests from `agent/tool_test.exs`. These test the `RLM.Tools.*`
modules directly (`execute/N` functions). Uses the same per-test temp directory
pattern. Tests can run `async: true` since they have no global state.

Cover:
- `RLM.Tools.ReadFile.execute/1` — read existing, nonexistent, large files
- `RLM.Tools.WriteFile.execute/2` — create new, overwrite, parent dir creation
- `RLM.Tools.EditFile.execute/3` — unique replacement, not found, non-unique
- `RLM.Tools.Bash.execute/2` — stdout, exit codes, timeout, cwd
- `RLM.Tools.Grep.execute/2` — pattern matching, glob filter, truncation
- `RLM.Tools.Glob.execute/2` — wildcard matching, no matches
- `RLM.Tools.Ls.execute/1` — directory listing, nonexistent path
- `RLM.Tools.Registry` — `all/0`, `list/0`, `doc/1`

**New file:** `test/rlm/sandbox_test.exs`

Test the sandbox wrappers:
- `unwrap!` raises on `{:error, _}`, returns value on `{:ok, _}`
- `list_tools/0` returns a list of `{name, summary}` tuples
- `tool_help/1` returns a doc string for known tools, nil for unknown
- Integration: `read_file/1` called through `RLM.Eval.run/3` actually reads a file

**New file:** `test/rlm/worker_multiturn_test.exs`

Test the multi-turn Worker:
- Start Worker with `keep_alive: true`
- First query sets `final_answer` → reply received, Worker stays alive
- Second query via `handle_call({:send_message, ...})` → new iteration, new answer
- `handle_call(:history, ...)` returns accumulated messages
- `handle_call(:status, ...)` returns stats
- Rejection of `send_message` while `:running`

### 9.3 Tests to modify

**Modified file:** `test/rlm/integration_test.exs`

No changes expected — tests `RLM.run/3` which is unchanged.

**Modified file:** `test/rlm/worker_test.exs`

Add tests for new `handle_call` clauses (`:send_message`, `:history`, `:status`).

### 9.4 Test support — no changes

`test/support/mock_llm.ex` stays as-is. It mocks `RLM.LLM`, which is unchanged.
The inline `MockAgentLLM` in `session_test.exs` is deleted with that file.

---

## Phase 10 — Documentation

### 10.1 `CLAUDE.md`

**Modified file:** `/home/user/exrlm/CLAUDE.md`

- **Project structure:** Remove `agent/` subtree. Add `tools/` subtree under `lib/rlm/`.
- **Module Map:** Remove "Coding Agent" section. Add rows for `RLM.Tool`,
  `RLM.Tools.Registry`, `RLM.Tools.*` (7 tools), `RLM.IEx`. Update `RLM.Sandbox`
  description to mention file/shell/search functions.
- **Config Fields:** Remove `agent_llm_module` row. Add `keep_alive` row.
- **OTP Supervision Tree:** Remove `RLM.AgentSup`.
- **Testing Conventions:** Remove mention of Agent tool tests and `MockAgentLLM`.
  Add section on `RLM.Tools` tests (async: true, temp dirs).
- **Key Design Decisions:** Remove "SSE Streaming" section. Add "Multi-turn
  Workers" section explaining `keep_alive` mode.

### 10.2 `CHANGELOG.md`

**Modified file:** `/home/user/exrlm/CHANGELOG.md`

Add entry under `## [Unreleased]`:

```markdown
### Changed
- Consolidated `RLM.Agent.*` into the RLM engine — tools are now sandbox
  functions callable from eval'd code
- `RLM.Worker` supports multi-turn conversation via `keep_alive: true` config
- Expanded `RLM.Sandbox` with file I/O, bash, grep, glob, ls functions
- Added runtime tool discovery: `list_tools/0` and `tool_help/1`

### Added
- `RLM.Tools.*` — 7 tool modules with `RLM.Tool` behaviour for discoverability
- `RLM.Tools.Registry` — tool listing and doc introspection
- `RLM.IEx` — rewritten IEx helpers using Worker multi-turn mode
- `RLM.send_message/2` — send follow-up messages to a keep-alive Worker

### Removed
- `RLM.Agent.LLM`, `RLM.Agent.Message`, `RLM.Agent.Session`, `RLM.Agent.Prompt`,
  `RLM.Agent.Tool`, `RLM.Agent.ToolRegistry`, `RLM.Agent.IEx`
- All `RLM.Agent.Tools.*` modules (8 tools)
- `RLM.AgentSup` DynamicSupervisor
- `agent_llm_module` config field
```

### 10.3 `README.md`

**Modified file:** `/home/user/exrlm/README.md`

- Remove "Using the Coding Agent" section entirely
- Expand RLM usage section to show file/shell tools in sandbox examples
- Update IEx helpers section: `import RLM.IEx` instead of `RLM.Agent.IEx`
- Update project structure diagram
- Update available tools table (now sandbox functions, not agent tools)
- Update architecture diagram: one engine, no agent path

### 10.4 `apps/rlm/mix.exs`

**Modified file:** `apps/rlm/mix.exs`

Remove "Coding Agent" and "Agent Tools" ExDoc groups. Add "Tools" group listing
`RLM.Tool`, `RLM.Tools.Registry`, and the 7 `RLM.Tools.*` modules.

### 10.5 `GUIDE.html`

**Needs regeneration.** Section 5 (Coding Agent Deep-Dive) should be removed.
Tool documentation should move into the RLM Engine sections. The OTP tree
diagram should drop `RLM.AgentSup`.

### 10.6 `SPEC.md`

No changes. This is a historical document describing the original agent design.

### 10.7 `ARCHITECTURE_REVIEW.md`

No changes. This is the analysis that motivated the consolidation.

---

## Execution Order

The phases can be partially parallelized:

```
Phase 1 (Tool modules)  ─┐
Phase 2 (Sandbox)        ─┤─→ Phase 8 (Delete agent) ─→ Phase 10 (Docs)
Phase 3 (Multi-turn)     ─┤
Phase 4 (IEx helpers)    ─┤
Phase 5 (PubSub)         ─┤
Phase 6 (System prompt)  ─┤
Phase 7 (Config cleanup) ─┘
                               Phase 9 (Tests) — alongside phases 1-7
```

Recommended serial order for a single developer:

1. **Phase 1** — Create `RLM.Tools.*` modules (pure, testable, no dependencies)
2. **Phase 9.2 (partial)** — Write `tools_test.exs` to verify tool modules
3. **Phase 2** — Expand `RLM.Sandbox` with wrappers and discovery
4. **Phase 9.2 (partial)** — Write `sandbox_test.exs`
5. **Phase 3** — Multi-turn Worker changes
6. **Phase 9.2 (partial)** — Write `worker_multiturn_test.exs`
7. **Phase 4** — Rewrite IEx helpers
8. **Phase 5** — PubSub on Worker
9. **Phase 6** — System prompt expansion
10. **Phase 7** — Config cleanup
11. **Phase 8** — Delete all `Agent.*` files
12. **Phase 9.1** — Delete agent tests
13. **Phase 10** — Update all documentation

### Verification gates

After each phase, run:
```bash
mix compile --warnings-as-errors
mix test
mix format --check-formatted
```

After Phase 8 + 9.1 (deletions), additionally verify no dangling references:
```bash
grep -r "RLM.Agent" apps/rlm/lib/ apps/rlm/test/
grep -r "AgentSup" apps/rlm/lib/
grep -r "agent_llm_module" apps/rlm/lib/ config/
```

---

## File Inventory

### New files (10)

```
lib/rlm/tool.ex                    # RLM.Tool behaviour
lib/rlm/tools/registry.ex          # RLM.Tools.Registry
lib/rlm/tools/read_file.ex         # RLM.Tools.ReadFile
lib/rlm/tools/write_file.ex        # RLM.Tools.WriteFile
lib/rlm/tools/edit_file.ex         # RLM.Tools.EditFile
lib/rlm/tools/bash.ex              # RLM.Tools.Bash
lib/rlm/tools/grep.ex              # RLM.Tools.Grep
lib/rlm/tools/glob.ex              # RLM.Tools.Glob
lib/rlm/tools/ls.ex                # RLM.Tools.Ls
lib/rlm/iex.ex                     # RLM.IEx
```

### New test files (3)

```
test/rlm/tools_test.exs            # Tool module unit tests
test/rlm/sandbox_test.exs          # Sandbox wrapper + discovery tests
test/rlm/worker_multiturn_test.exs # Multi-turn Worker tests
```

### Modified files (9)

```
lib/rlm/sandbox.ex                 # Add tool wrappers + discovery
lib/rlm/eval.ex                    # Inject :rlm_cwd into process dict
lib/rlm/worker.ex                  # Multi-turn: keep_alive, send_message, history, status
lib/rlm.ex                         # Add send_message/2
lib/rlm/config.ex                  # Remove agent_llm_module, add keep_alive
lib/rlm/application.ex             # Remove AgentSup
lib/rlm/prompt.ex                  # Update default_system_prompt fallback
apps/rlm/priv/system_prompt.md     # Expand with tool docs
apps/rlm/mix.exs                   # Update ExDoc groups
```

### Modified docs (4)

```
CLAUDE.md                          # Module map, config, supervision tree
CHANGELOG.md                       # Consolidation entry
README.md                          # Remove agent section, update examples
GUIDE.html                         # Regenerate (remove agent deep-dive)
```

### Deleted source files (15)

```
lib/rlm/agent/llm.ex
lib/rlm/agent/message.ex
lib/rlm/agent/session.ex
lib/rlm/agent/prompt.ex
lib/rlm/agent/tool.ex
lib/rlm/agent/tool_registry.ex
lib/rlm/agent/iex.ex
lib/rlm/agent/tools/read_file.ex
lib/rlm/agent/tools/write_file.ex
lib/rlm/agent/tools/edit_file.ex
lib/rlm/agent/tools/bash.ex
lib/rlm/agent/tools/grep.ex
lib/rlm/agent/tools/glob.ex
lib/rlm/agent/tools/ls.ex
lib/rlm/agent/tools/rlm_query.ex
```

### Deleted test files (3)

```
test/rlm/agent/llm_test.exs
test/rlm/agent/session_test.exs
test/rlm/agent/tool_test.exs
```

### Unchanged files (8)

```
test/rlm/integration_test.exs
test/rlm/live_api_test.exs
test/rlm/helpers_test.exs
test/rlm/worker_test.exs
test/support/mock_llm.ex
test/test_helper.exs
config/config.exs
SPEC.md
ARCHITECTURE_REVIEW.md
```
