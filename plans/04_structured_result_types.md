# Plan: Structured Result Types

## Motivation

Currently, all results in RLM are strings:

- `RLM.run/3` returns `{:ok, answer_string, run_id}`
- `lm_query/2` returns `{:ok, string}` or `{:error, string}`
- `final_answer` is typically a string (though it can be any term)
- Tool results are `{:ok, String.t()} | {:error, String.t()}`

This works, but it means:
- No metadata travels with results (confidence, token usage, source span_id)
- Parent workers can't distinguish structured data from freeform text in subcall results
- There's no standard way to type-check what a subcall returns

Jido's schema-validated Actions show that optional type contracts on inputs/outputs
add safety without sacrificing flexibility. We can apply this to RLM's binding system.

## Design

### `RLM.Result` Struct

A lightweight wrapper that can optionally carry metadata alongside the value:

```elixir
defmodule RLM.Result do
  @moduledoc """
  Optional structured result wrapper for RLM values.

  Workers and eval'd code can use plain values (strings, maps, etc.) as before.
  Wrapping in `%RLM.Result{}` adds metadata that persists through the binding system.

  ## Usage in eval'd code

      # Simple — same as setting final_answer to a string
      final_answer = "the answer"

      # Structured — carries metadata
      final_answer = %RLM.Result{value: computed_data, metadata: %{source: "analysis"}}

      # From a subcall — metadata is attached automatically
      {:ok, result} = lm_query("analyze this")
      # result is a string (backward compatible)

      # Structured subcall — request validated output
      {:ok, result} = lm_query("extract names", schema: name_schema)
      # result is a map (already works via direct_query)
  """

  @type t :: %__MODULE__{
    value: any(),
    metadata: map()
  }

  defstruct value: nil, metadata: %{}

  @doc "Unwrap a Result to its value. Passes through non-Result terms."
  @spec unwrap(t() | any()) :: any()
  def unwrap(%__MODULE__{value: v}), do: v
  def unwrap(other), do: other

  @doc "Wrap a value in a Result with optional metadata."
  @spec wrap(any(), map()) :: t()
  def wrap(value, metadata \\ %{}), do: %__MODULE__{value: value, metadata: metadata}

  @doc "Get metadata from a Result. Returns empty map for non-Result terms."
  @spec metadata(t() | any()) :: map()
  def metadata(%__MODULE__{metadata: m}), do: m
  def metadata(_), do: %{}
end
```

### Worker Changes: Result-Aware Completion

The Worker's `complete/2` function and `handle_eval_complete/2` need to
handle `%RLM.Result{}` in the `final_answer` binding:

```elixir
# In handle_eval_complete, success path:
final_answer = Keyword.get(new_bindings, :final_answer)

# Extract the actual value for the result, preserving backward compatibility
result_value = RLM.Result.unwrap(final_answer)

if final_answer != nil do
  complete(state, {:ok, result_value})
else
  send(self(), :iterate)
  {:noreply, state}
end
```

The key insight: `RLM.Result.unwrap/1` is a no-op for non-Result terms. So
`final_answer = "hello"` still works exactly as before, while
`final_answer = %RLM.Result{value: data, metadata: %{confidence: 0.95}}`
extracts `data` as the return value.

### Sandbox Changes: Result Metadata on Subcalls

When a subcall completes, attach span metadata to the result:

```elixir
# In Worker handle_info({:rlm_result, child_span_id, result}):
enriched_result = case result do
  {:ok, value} ->
    {:ok, RLM.Result.wrap(value, %{source_span_id: child_span_id, type: :subcall})}
  error -> error
end

GenServer.reply(from, enriched_result)
```

This is **opt-in enrichment**. Eval'd code that just does `{:ok, text} = lm_query("...")`
still works because `RLM.Result.unwrap/1` extracts the string. Code that wants metadata
can pattern match on the struct.

### Sandbox Helper for Result Construction

Add to `RLM.Sandbox`:

```elixir
@doc "Wrap a value with metadata for structured results."
def result(value, metadata \\ %{}) do
  RLM.Result.wrap(value, metadata)
end
```

This lets eval'd code write:

```elixir
final_answer = result(computed_data, %{confidence: 0.95, method: "map_reduce"})
```

## Files to Create

| File | Purpose |
|---|---|
| `lib/rlm/result.ex` | `RLM.Result` struct with `wrap/2`, `unwrap/1`, `metadata/1` |
| `test/rlm/result_test.exs` | Unit tests for Result functions |

## Files to Modify

| File | Change |
|---|---|
| `lib/rlm/worker.ex` | Use `RLM.Result.unwrap/1` when extracting `final_answer` value |
| `lib/rlm/sandbox.ex` | Add `result/2` helper function |

## Test Plan

```elixir
defmodule RLM.ResultTest do
  use ExUnit.Case, async: true
  alias RLM.Result

  test "wrap/1 creates a Result with empty metadata" do
    r = Result.wrap("hello")
    assert r.value == "hello"
    assert r.metadata == %{}
  end

  test "wrap/2 creates a Result with metadata" do
    r = Result.wrap(42, %{confidence: 0.9})
    assert r.value == 42
    assert r.metadata.confidence == 0.9
  end

  test "unwrap/1 extracts value from Result" do
    assert 42 == Result.unwrap(%Result{value: 42})
  end

  test "unwrap/1 passes through non-Result terms" do
    assert "hello" == Result.unwrap("hello")
    assert 42 == Result.unwrap(42)
    assert nil == Result.unwrap(nil)
  end

  test "metadata/1 returns metadata from Result" do
    r = %Result{value: 1, metadata: %{source: "test"}}
    assert Result.metadata(r) == %{source: "test"}
  end

  test "metadata/1 returns empty map for non-Result" do
    assert Result.metadata("string") == %{}
    assert Result.metadata(nil) == %{}
  end
end
```

Integration test with Worker (async: false):

```elixir
defmodule RLM.Worker.ResultIntegrationTest do
  use ExUnit.Case, async: false
  alias RLM.Test.{MockLLM, Helpers}

  test "plain final_answer still works" do
    MockLLM.program_responses([
      MockLLM.mock_response(~s(final_answer = "plain string"))
    ])

    %{run_pid: run_pid, config: config} = Helpers.start_test_run([])
    {:ok, _} = RLM.Run.start_worker(run_pid, [
      context: "test", config: config, caller: self()
    ])

    assert_receive {:rlm_result, _, {:ok, "plain string"}}, 5_000
  end

  test "Result-wrapped final_answer extracts value" do
    MockLLM.program_responses([
      MockLLM.mock_response(~s(final_answer = %RLM.Result{value: "structured", metadata: %{confidence: 0.95}}))
    ])

    %{run_pid: run_pid, config: config} = Helpers.start_test_run([])
    {:ok, _} = RLM.Run.start_worker(run_pid, [
      context: "test", config: config, caller: self()
    ])

    assert_receive {:rlm_result, _, {:ok, "structured"}}, 5_000
  end
end
```

## Documentation Updates

- **CLAUDE.md Module Map**: Add row for `RLM.Result`
- **CHANGELOG.md**: Entry under `Added`

## Verification

```bash
mix compile --warnings-as-errors
mix test
mix format --check-formatted
mix docs
```

## Design Rationale

- **Backward compatible by construction**: `unwrap/1` on a non-Result term returns the
  term itself. Every existing `final_answer = "string"` continues to work without change.
- **No new process state**: Result is a plain struct, stored in bindings like any other
  value. No new GenServer state, no new messages.
- **Metadata is advisory**: Nothing in the engine *requires* metadata. It's there for
  code that wants it — observability, provenance tracking, confidence scoring. The LLM
  can use it or ignore it.
- **Minimal surface area**: Three functions (`wrap`, `unwrap`, `metadata`) and one struct.
  This is the smallest useful abstraction for typed results.
- **Subcall enrichment is optional**: The Worker *can* wrap subcall results with span
  metadata, but this is a small change in one `handle_info` clause. If it causes issues,
  it can be gated behind a config flag.
