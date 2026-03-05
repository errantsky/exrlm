# Plan: Deterministic Replay

## Motivation

RLM's EventLog already captures a detailed trace of every run: each iteration's LLM
response, code, eval result, stdout, bindings snapshot, subcall spawns, and timing data.
This trace is stored in both an in-memory Agent (per-run) and a `:dets` table (persistent).

But the trace is **read-only forensics**. You can inspect what happened, but you can't
re-run it. Deterministic replay would let you:

- **Debug**: Replay a failed run, patching one iteration's code to see if a different
  approach works
- **Regression test**: Record a successful run, replay it against a new codebase version
  to verify the same code still produces the same results
- **Model comparison**: Replay with a different LLM model to compare quality
- **Cost optimization**: Replay the eval steps without making any LLM calls

This is the most architecturally significant feature — it builds on EventLog's existing
data and creates a new execution path through the Worker.

## Design

### Recording: Extend EventLog with LLM Responses

The current EventLog captures `code` and `reasoning` (from `iteration_stop` events)
but not the **full raw LLM response**. For replay, we need the exact response text
that produced each iteration's code.

Add a new event type emitted from Worker right after a successful LLM call:

```elixir
# In Worker.handle_info(:iterate), after llm_module.chat succeeds:
emit_telemetry([:rlm, :llm, :response, :recorded], %{}, state, %{
  iteration: state.iteration,
  response: response,  # full raw LLM response text
  usage: usage
})
```

And the corresponding handler in `EventLogHandler`:

```elixir
def handle_event([:rlm, :llm, :response, :recorded], _measurements, metadata, _config) do
  event = %{
    type: :llm_response,
    span_id: metadata.span_id,
    iteration: metadata[:iteration],
    response: metadata[:response],
    usage: metadata[:usage],
    timestamp_us: System.system_time(:microsecond)
  }

  RLM.EventLog.append(metadata.run_id, event)
  RLM.TraceStore.put_event(metadata.run_id, event)
end
```

### Recording: Config Flag

Recording the full LLM response increases storage. Gate it behind a config flag:

```elixir
# In Config
:enable_replay_recording  # default: false
```

The Worker checks this flag before emitting the `:llm_response` event.

### Replay Data Structure

A replay tape is built from a recorded run's events:

```elixir
defmodule RLM.Replay.Tape do
  @moduledoc """
  A replay tape: an ordered sequence of LLM responses from a recorded run.
  Built from EventLog events, consumed by the replay LLM module.
  """

  defstruct [:run_id, :context, :query, entries: []]

  @type entry :: %{
    iteration: non_neg_integer(),
    span_id: String.t(),
    response: String.t(),
    usage: map()
  }

  @type t :: %__MODULE__{
    run_id: String.t(),
    context: String.t() | nil,
    query: String.t() | nil,
    entries: [entry()]
  }

  @doc "Build a tape from EventLog events for a given run."
  @spec from_events(String.t()) :: {:ok, t()} | {:error, :no_events | :no_responses}
  def from_events(run_id) do
    events = RLM.EventLog.get_events(run_id)
    |> fallback_to_store(run_id)

    if events == [] do
      {:error, :no_events}
    else
      responses = events
      |> Enum.filter(&(&1.type == :llm_response))
      |> Enum.sort_by(& &1.iteration)
      |> Enum.map(fn e ->
        %{iteration: e.iteration, span_id: e.span_id, response: e.response, usage: e.usage}
      end)

      if responses == [] do
        {:error, :no_responses}
      else
        {:ok, %__MODULE__{run_id: run_id, entries: responses}}
      end
    end
  end

  defp fallback_to_store([], run_id), do: RLM.EventLog.get_events_from_store(run_id)
  defp fallback_to_store(events, _), do: events
end
```

### Replay LLM Module

A module that implements the `RLM.LLM` behaviour but returns responses from a tape
instead of calling the API:

```elixir
defmodule RLM.Replay.LLM do
  @moduledoc """
  An LLM module that replays responses from a recorded tape.
  Used by `RLM.replay/2` to re-execute a run deterministically.

  Responses are consumed in order. If the tape runs out (e.g., because a patch
  caused additional iterations), falls back to a real LLM or returns an error.
  """

  @behaviour RLM.LLM

  @impl true
  def chat(_messages, _model, _config, _opts \\ []) do
    case pop_entry() do
      nil ->
        {:error, "Replay tape exhausted — no more recorded responses"}

      entry ->
        {:ok, entry.response, entry.usage}
    end
  end

  @doc "Initialize the replay state for the current process."
  def load_tape(%RLM.Replay.Tape{entries: entries}) do
    Process.put(:rlm_replay_entries, entries)
  end

  defp pop_entry do
    case Process.get(:rlm_replay_entries, []) do
      [] -> nil
      [entry | rest] ->
        Process.put(:rlm_replay_entries, rest)
        entry
    end
  end
end
```

**Note on process dictionary**: This uses the process dict because the LLM module's
`chat/4` callback doesn't have a slot for replay state. Since Worker calls `chat/4`
synchronously from its own process, the tape state lives in the Worker's process dict.
This requires `load_tape/1` to be called from the Worker process — handled by the
replay orchestrator.

### Replay Orchestrator

```elixir
defmodule RLM.Replay do
  @moduledoc """
  Replay a previously recorded RLM run.

  Replays use the recorded LLM responses but re-execute all eval'd code.
  This verifies that the same code still works against the current environment.

  ## Options

    * `:patch` — `%{iteration => code}` map. At the specified iteration, the
      patched code replaces the LLM's code before eval. The LLM response is
      still consumed from the tape (to maintain iteration alignment).
    * `:config` — config overrides applied to the replay run
    * `:fallback` — what to do when the tape runs out:
      - `:error` (default) — return an error
      - `:live` — switch to live LLM calls for remaining iterations
  """

  @spec replay(String.t(), keyword()) :: {:ok, any(), String.t()} | {:error, any()}
  def replay(run_id, opts \\ []) do
    patches = Keyword.get(opts, :patch, %{})
    config_overrides = Keyword.get(opts, :config, [])
    fallback = Keyword.get(opts, :fallback, :error)

    with {:ok, tape} <- RLM.Replay.Tape.from_events(run_id) do
      # Build config with replay LLM module
      llm_module = if fallback == :live do
        # Wrap: try replay first, fall back to live
        RLM.Replay.FallbackLLM
      else
        RLM.Replay.LLM
      end

      config = RLM.Config.load(
        Keyword.merge(config_overrides, [
          llm_module: llm_module,
          enable_replay_recording: false  # don't record replays
        ])
      )

      # Extract original context and query from the tape's node_start event
      events = get_events(run_id)
      {context, query} = extract_original_input(events)

      # Start the replay run
      # The tape is loaded into the Worker process via an init hook
      replay_run_id = RLM.Span.generate_run_id()

      {:ok, run_pid} = DynamicSupervisor.start_child(RLM.RunSup, {
        RLM.Run, run_id: replay_run_id, config: config, keep_alive: false
      })

      # Load tape and patches into process dict before starting worker
      # This requires a custom init path — use a wrapper
      worker_opts = [
        context: context || "",
        query: query || context || "",
        config: config,
        caller: self(),
        replay_tape: tape,
        replay_patches: patches
      ]

      {:ok, _worker_pid} = RLM.Run.start_worker(run_pid, worker_opts)

      # Wait for result (same as RLM.run/3)
      timeout = config.eval_timeout * 2
      receive do
        {:rlm_result, _span_id, result} -> {:ok, elem(result, 1), replay_run_id}
      after
        timeout -> {:error, :timeout}
      end
    end
  end

  defp get_events(run_id) do
    case RLM.EventLog.get_events(run_id) do
      [] -> RLM.EventLog.get_events_from_store(run_id)
      events -> events
    end
  end

  defp extract_original_input(events) do
    node_start = Enum.find(events, &(&1.type == :node_start && &1.depth == 0))
    # Context and query aren't stored in events currently —
    # they'd need to be added to the node_start event
    {nil, nil}
  end
end
```

### Worker Replay Integration

The Worker needs to support the replay tape. Two changes:

**1. Load tape during init:**

```elixir
# In Worker.init/1, after building state:
tape = Keyword.get(opts, :replay_tape)
patches = Keyword.get(opts, :replay_patches, %{})

if tape do
  RLM.Replay.LLM.load_tape(tape)
end

state = %{state | replay_patches: patches}
```

**2. Apply patches before eval:**

```elixir
# In handle_info(:iterate), after extract_structured succeeds:
code = case Map.get(state.replay_patches, state.iteration) do
  nil -> code
  patched_code -> patched_code
end
```

Add `:replay_patches` to the Worker struct (default `%{}`).

### Recording Context in node_start

For replay to work end-to-end, the original context and query must be recoverable.
Add them to the `node_start` telemetry event (for depth-0 workers only):

```elixir
# In Worker.init, one-shot mode, when emitting [:rlm, :node, :start]:
emit_telemetry([:rlm, :node, :start], %{}, state, %{
  context_bytes: context_bytes,
  query_preview: String.slice(query, 0, 200),
  # New fields for replay (depth 0 only):
  original_context: if(state.depth == 0, do: context),
  original_query: if(state.depth == 0, do: query)
})
```

And store these in the EventLog event.

## Files to Create

| File | Purpose |
|---|---|
| `lib/rlm/replay.ex` | Replay orchestrator: `replay/2` |
| `lib/rlm/replay/tape.ex` | Tape struct + `from_events/1` builder |
| `lib/rlm/replay/llm.ex` | LLM behaviour impl that reads from tape |
| `test/rlm/replay_test.exs` | Replay integration tests |
| `test/rlm/replay/tape_test.exs` | Tape construction tests |

## Files to Modify

| File | Change |
|---|---|
| `lib/rlm/worker.ex` | Add `:replay_patches` to struct, apply patches before eval, emit llm_response event, load tape on init |
| `lib/rlm/config.ex` | Add `:enable_replay_recording` field |
| `lib/rlm/telemetry/event_log_handler.ex` | Handle `:llm_response` event type |
| `lib/rlm.ex` | Add `RLM.replay/2` public API delegation |

## Test Plan

```elixir
defmodule RLM.Replay.TapeTest do
  use ExUnit.Case, async: true
  alias RLM.Replay.Tape

  test "from_events returns error for empty events" do
    assert {:error, :no_events} = Tape.from_events("nonexistent_run")
  end
end

defmodule RLM.ReplayTest do
  use ExUnit.Case, async: false
  alias RLM.Test.{MockLLM, Helpers}

  test "replay with tape reproduces the same result" do
    # Step 1: Record a run
    MockLLM.program_responses([
      MockLLM.mock_response("x = 1 + 2", "computing"),
      MockLLM.mock_response(~s(final_answer = "result: #{x}"), "finishing")  # would need interpolation
    ])

    # For this test, use a simpler single-iteration run
    MockLLM.program_responses([
      MockLLM.mock_response(~s(final_answer = "hello"))
    ])

    config = RLM.Config.load(
      llm_module: MockLLM,
      enable_replay_recording: true
    )

    {:ok, answer, run_id} = RLM.run("test context", "say hello", config: config)
    assert answer == "hello"

    # Step 2: Build tape from recorded events
    {:ok, tape} = RLM.Replay.Tape.from_events(run_id)
    assert length(tape.entries) >= 1

    # Step 3: Replay
    {:ok, replay_answer, _replay_run_id} = RLM.Replay.replay(run_id)
    assert replay_answer == "hello"
  end

  test "replay with patch modifies one iteration" do
    MockLLM.program_responses([
      MockLLM.mock_response(~s(final_answer = "original"))
    ])

    config = RLM.Config.load(
      llm_module: MockLLM,
      enable_replay_recording: true
    )

    {:ok, "original", run_id} = RLM.run("ctx", "task", config: config)

    # Replay with patched code at iteration 0
    {:ok, answer, _} = RLM.Replay.replay(run_id,
      patch: %{0 => ~s(final_answer = "patched")}
    )

    assert answer == "patched"
  end
end
```

## Phased Implementation

This is the most complex feature. Implement in phases:

### Phase 1: Recording
- Add `enable_replay_recording` config flag
- Emit `[:rlm, :llm, :response, :recorded]` telemetry event from Worker
- Handle the event in EventLogHandler
- Store original context/query in node_start event
- **Test**: Verify events are recorded and retrievable

### Phase 2: Tape + Replay LLM
- Implement `RLM.Replay.Tape.from_events/1`
- Implement `RLM.Replay.LLM` (process-dict based tape consumer)
- **Test**: Build tape from recorded events, verify LLM module returns them in order

### Phase 3: Replay Orchestrator
- Implement `RLM.Replay.replay/2`
- Add `:replay_patches` to Worker struct
- Add tape loading to Worker init
- Add patch application before eval
- **Test**: Full replay integration test

### Phase 4: Public API
- Add `RLM.replay/2` to public API in `lib/rlm.ex`
- **Test**: End-to-end test via public API

## Documentation Updates

- **CLAUDE.md Module Map**: Add rows for `RLM.Replay`, `RLM.Replay.Tape`, `RLM.Replay.LLM`
- **CLAUDE.md Config Fields**: Add `enable_replay_recording` row
- **CHANGELOG.md**: Entry under `Added`
- **README.md**: Add replay usage example

## Verification

```bash
mix compile --warnings-as-errors
mix test
mix format --check-formatted
mix docs
```

## Design Rationale

- **Process dictionary for tape state**: The `RLM.LLM` behaviour's `chat/4` signature
  doesn't have a replay-state argument. Rather than changing the behaviour (which would
  break all implementations), we use the process dict — the Worker calls `chat/4`
  synchronously from its own process, so the tape is always accessible. This matches
  the existing pattern where `RLM.Eval` uses process dict for `worker_pid`, `cwd`, etc.
- **Patches are code-level, not response-level**: Patching replaces the *code* that gets
  eval'd, not the LLM response. The tape entry is still consumed to maintain iteration
  alignment. This is the most useful granularity — you want to try different code, not
  different LLM outputs.
- **Recording is opt-in**: Full LLM responses can be large. The `enable_replay_recording`
  flag (default false) ensures no storage overhead for runs that won't be replayed.
- **Subcall replay is deferred**: This plan replays only the root worker's iterations.
  Subcall replay (replaying child workers with their own tapes) is a natural extension
  but adds significant complexity. Start with root-only replay, extend later.
- **No serialization format**: Tapes live in EventLog/TraceStore (:dets). No need for
  JSON export yet — that can be added when cross-machine replay is needed.
