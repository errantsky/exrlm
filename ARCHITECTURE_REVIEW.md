# Architecture Review: RLM + Agent Consolidation

## Summary

The separation between the RLM engine and the Coding Agent is not necessary.
A consolidated RLM agent — where tools are normal Elixir functions in the eval
sandbox — would be simpler, more capable, and more idiomatic OTP.

## Current Duplication

| Concern              | RLM Engine             | Agent                          | Consolidated      |
|----------------------|------------------------|--------------------------------|--------------------|
| LLM client           | `RLM.LLM` (111 LOC)   | `RLM.Agent.LLM` (327 LOC)     | One client         |
| Loop GenServer       | `RLM.Worker` (540 LOC) | `RLM.Agent.Session` (302 LOC) | One GenServer      |
| Tool dispatch        | `RLM.Sandbox` (56 LOC) | `ToolRegistry` + `Tool` (116 LOC) | Sandbox functions |
| Prompt builder       | `RLM.Prompt` (114 LOC) | `RLM.Agent.Prompt` (68 LOC)   | One prompt         |
| Message helpers      | Inline in Worker       | `RLM.Agent.Message` (119 LOC) | Simplified         |
| DynamicSupervisor    | `RLM.WorkerSup`        | `RLM.AgentSup`                | One supervisor     |
| Config injection     | `llm_module`            | `agent_llm_module`            | One injection point|

The two engines solve the same problem (multi-turn LLM loop with side effects)
using two different protocols. The RLM engine uses `Code.eval_string` with
injected sandbox functions. The Agent uses Anthropic's `tool_use` JSON schema.

## Why the RLM Engine Pattern Is the Stronger Foundation

### 1. Tools as Functions Are More Natural

Instead of the Anthropic tool_use protocol (JSON schema spec, deserialized map
input, string output), tools become normal functions:

```elixir
# LLM writes this directly in its code block:
content = read_file("lib/my_app/worker.ex")
lines = String.split(content, "\n")
matching = Enum.filter(lines, &String.contains?(&1, "TODO"))
IO.puts("Found #{length(matching)} TODOs")
```

The agent approach requires 3+ separate tool calls with JSON serialization and
Anthropic API round-trips for the same operation.

### 2. The Async-Eval Pattern Already Solves the Hard Problem

The Worker's design — eval spawns in a separate process so the GenServer mailbox
stays free for subcalls — is the correct OTP solution. The Agent's Task.Supervisor
approach is a parallel invention solving the same problem.

### 3. Data Stays as Elixir Terms

In the agent model, everything is a string. In the RLM model, data lives in
bindings as proper Elixir data structures across iterations. No serialization
overhead.

### 4. Composition Is Free

One eval iteration replaces 4+ tool calls:

```elixir
"lib/**/*.ex"
|> Path.wildcard()
|> Enum.map(&{&1, File.read!(&1)})
|> Enum.filter(fn {_, content} -> content =~ ~r/defmodule.*Controller/ end)
|> Enum.map(fn {path, _} -> path end)
```

### 5. Recursive Subcalls Are Native

The agent needed a bridge tool (`rlm_query`) to access the RLM engine. A
consolidated engine has `lm_query/2` natively — no bridge needed.

## Proposed Consolidated Architecture

### Supervision Tree

```
RLM.Supervisor (one_for_one)
├── Registry
├── Phoenix.PubSub
├── Task.Supervisor
├── DynamicSupervisor (RLM.WorkerSup)
├── DynamicSupervisor (RLM.EventStore)
├── RLM.Telemetry
└── RLM.EventLog.Sweeper
```

AgentSup is removed. One fewer DynamicSupervisor.

### Expanded Sandbox

```elixir
defmodule RLM.Sandbox do
  # Existing helpers
  def chunks(string, size), do: ...
  def grep(pattern, string), do: ...
  def preview(string, n), do: ...
  def list_bindings(), do: ...
  def lm_query(text, opts \\ []), do: ...

  # Former Agent tools — now plain functions
  def read_file(path), do: ...
  def write_file(path, content), do: ...
  def edit_file(path, old_string, new_string), do: ...
  def bash(command, opts \\ []), do: ...
  def grep_files(pattern, opts \\ []), do: ...
  def glob(pattern), do: ...
  def ls(path \\ "."), do: ...
end
```

Each function is a thin wrapper around the same underlying operations. `bash/2`
still uses `Task.async` + `Task.yield`. `read_file/1` still caps at 100KB. The
implementations transfer directly from `RLM.Agent.Tools.*`.

### What Gets Removed

- `RLM.Agent.Session` (302 LOC)
- `RLM.Agent.LLM` (327 LOC)
- `RLM.Agent.Tool` (57 LOC)
- `RLM.Agent.ToolRegistry` (59 LOC)
- `RLM.Agent.Message` (119 LOC)
- `RLM.Agent.Prompt` (68 LOC)
- All `RLM.Agent.Tools.*` modules (~280 LOC)
- `RLM.Agent.IEx` (rewritten to use `RLM.run/3`)

**Total removed: ~1,200 LOC**
**Added (sandbox functions + prompt expansion): ~200 LOC**
**Net reduction: ~1,000 LOC**

## What You Lose (And Why It's Acceptable)

### Structured Tool Definitions
The `tool_use` protocol gives the LLM a formal JSON schema per tool. But Claude
already writes correct Elixir function calls when given documentation in the
system prompt — the existing sandbox functions prove this works.

### Per-Token SSE Streaming
The agent's SSE streaming is buffered anyway (Req/Finch adapter conflict). The
RLM engine emits telemetry events per iteration, which is better observability —
you see the decision, execution, and result rather than a token stream.

### Multi-Turn Conversation
The Worker currently terminates after `final_answer`. For interactive use, add
a `:keep_alive` mode or start a new Worker per query with accumulated context.

## What to Keep From the Agent

- **Tool implementations** — File I/O, bash, ripgrep, glob code transfers to sandbox
- **PubSub events** — Add PubSub broadcasts at Worker telemetry points for LiveView
- **IEx helpers** — Rewrite to wrap `RLM.run/3`

## Migration Path

1. Move `Agent.Tools.*` implementations into `RLM.Sandbox` as plain functions
2. Expand `RLM.Prompt` to document new sandbox functions
3. Add PubSub broadcasts to Worker telemetry points
4. Adapt `RLM.Agent.IEx` to use `RLM.run/3`
5. Delete all `Agent.*` modules
6. Remove `AgentSup` from supervision tree
7. Remove `agent_llm_module` from Config

## Evidence the Separation Was Wrong

The `rlm_query` bridge tool's existence is proof: the agent needed the RLM
engine's capabilities, which means those capabilities should have been in one
place from the start. Two engines calling the same API, running in the same
supervision tree, with one needing a bridge to the other, is a sign they
should be one engine.
