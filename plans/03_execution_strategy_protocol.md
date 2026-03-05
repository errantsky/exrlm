# Plan: Execution Strategy Protocol

## Motivation

The Worker's iterate loop has three decision points that are currently hardcoded:

1. **After eval completes**: Build feedback message, decide whether to stop or continue
2. **Completion check**: Is `final_answer` set?
3. **Nudge detection**: Are the last 3 codes too similar?

These are reasonable defaults, but they bake a single execution philosophy into the
Worker GenServer. Jido's Strategy protocol (Direct, FSM, InstructionTracking) shows
that the *decision logic* between steps can be swapped without changing the step
execution itself.

We can extract these decision points into a protocol, keeping the Worker as the
execution engine while making its judgment calls pluggable.

## Design

### The Protocol

```elixir
defprotocol RLM.Strategy do
  @moduledoc """
  Protocol for customizing Worker iteration decisions.

  The Worker handles all OTP mechanics (GenServer, async eval, subcall coordination).
  The Strategy handles the judgment calls between iterations.
  """

  @doc "Build the feedback message after eval completes."
  @spec build_feedback(t(), map()) :: map()
  def build_feedback(strategy, eval_context)

  @doc "Should we stop iterating? Returns {:stop, result} or :continue."
  @spec check_completion(t(), keyword(), map()) :: {:stop, {:ok | :error, any()}} | :continue
  def check_completion(strategy, bindings, eval_context)

  @doc "Optionally modify state between iterations. Returns updated history or nil."
  @spec between_iterations(t(), list(), list()) :: list() | nil
  def between_iterations(strategy, history, prev_codes)
end
```

### Default Implementation

A struct that preserves exactly the current behavior:

```elixir
defmodule RLM.Strategy.Default do
  @moduledoc """
  The standard RLM execution strategy.

  - Feedback: structured JSON with eval_status, stdout, bindings, final_answer_set
  - Completion: stops when `final_answer` binding is non-nil
  - Between iterations: nudge message when last 3 codes are >85% similar
  """

  defstruct []

  defimpl RLM.Strategy do
    def build_feedback(_strategy, %{eval_status: :ok} = ctx) do
      RLM.Prompt.build_feedback_message(
        ctx.truncated_output,
        :ok,
        ctx.bindings_info,
        ctx.final_answer != nil
      )
    end

    def build_feedback(_strategy, %{eval_status: :error} = ctx) do
      RLM.Prompt.build_feedback_message(
        ctx.truncated_output,
        :error,
        ctx.bindings_info,
        false
      )
    end

    def check_completion(_strategy, bindings, _ctx) do
      case Keyword.get(bindings, :final_answer) do
        nil -> :continue
        answer -> {:stop, {:ok, answer}}
      end
    end

    def between_iterations(_strategy, _history, prev_codes) do
      if length(prev_codes) >= 3 and codes_similar?(prev_codes) do
        [RLM.Prompt.build_nudge_message()]
      else
        nil
      end
    end

    defp codes_similar?([a, b, c | _]) do
      similarity(a, b) > 0.85 and similarity(b, c) > 0.85
    end
    defp codes_similar?(_), do: false

    defp similarity(a, b) do
      a_set = a |> String.split() |> MapSet.new()
      b_set = b |> String.split() |> MapSet.new()
      intersection = MapSet.intersection(a_set, b_set) |> MapSet.size()
      union = MapSet.union(a_set, b_set) |> MapSet.size()
      if union == 0, do: 1.0, else: intersection / union
    end
  end
end
```

### Worker Integration

Add a `:strategy` field to the Worker struct. The Worker calls the protocol
at each decision point instead of inline logic.

**Changes to Worker struct:**

```elixir
defstruct [
  # ... existing fields ...
  :strategy  # %RLM.Strategy.Default{} or custom
]
```

**Changes to `init/1`:**

```elixir
strategy = Keyword.get(opts, :strategy, %RLM.Strategy.Default{})
# ... add to state struct
```

**Changes to `handle_eval_complete/2` (success path, lines 526-586):**

Replace the inline feedback building and final_answer check:

```elixir
# Before (current):
feedback = RLM.Prompt.build_feedback_message(truncated, :ok, bindings_info, final_answer != nil)
# ... later ...
if final_answer != nil do
  complete(state, {:ok, final_answer})
else
  send(self(), :iterate)
  {:noreply, state}
end

# After (with strategy):
eval_ctx = %{
  eval_status: :ok,
  truncated_output: truncated,
  bindings_info: bindings_info,
  final_answer: final_answer,
  code: ctx.code,
  iteration: state.iteration
}

feedback = RLM.Strategy.build_feedback(state.strategy, eval_ctx)

state = %{state |
  history: state.history ++ [ctx.assistant_msg, feedback],
  bindings: new_bindings,
  iteration: state.iteration + 1,
  prev_codes: Enum.take([ctx.code | state.prev_codes], 3),
  eval_context: nil
}

# Replace maybe_nudge with strategy call
case RLM.Strategy.between_iterations(state.strategy, state.history, state.prev_codes) do
  nil -> :ok
  extra_msgs -> state = %{state | history: state.history ++ extra_msgs, prev_codes: []}
end

# Replace final_answer check with strategy call
case RLM.Strategy.check_completion(state.strategy, state.bindings, eval_ctx) do
  {:stop, result} -> complete(state, result)
  :continue ->
    send(self(), :iterate)
    {:noreply, state}
end
```

**Same pattern for error path (lines 588-637):**

```elixir
eval_ctx = %{
  eval_status: :error,
  truncated_output: truncated,
  bindings_info: bindings_info,
  final_answer: nil,
  code: ctx.code,
  iteration: state.iteration
}

feedback = RLM.Strategy.build_feedback(state.strategy, eval_ctx)
# ... rest uses :continue from check_completion (errors never stop) ...
```

### Config Integration

Add `:strategy` to `RLM.Config`:

```elixir
# In Config struct
:strategy

# In Config.load
strategy: get(overrides, :strategy, %RLM.Strategy.Default{})
```

The Worker reads it from config during init, but it can also be passed directly
via `opts` (useful for tests and `RLM.run/3` overrides).

### Example Custom Strategy: Plan-Then-Execute

To show the protocol's value, here's how a custom strategy would look (not
implemented as part of this plan, just documentation):

```elixir
defmodule RLM.Strategy.PlanFirst do
  @moduledoc """
  First iteration: LLM produces a plan (stored in `plan` binding).
  Subsequent iterations: execute plan steps sequentially.
  Completion: when `plan_complete` binding is truthy.
  """
  defstruct []

  defimpl RLM.Strategy do
    def build_feedback(_strategy, %{eval_status: :ok, iteration: 0} = ctx) do
      %{role: :user, content: Jason.encode!(%{
        "eval_status" => "ok",
        "phase" => "planning_complete",
        "stdout" => ctx.truncated_output,
        "message" => "Plan stored. Now execute step 1."
      })}
    end

    def build_feedback(_strategy, ctx) do
      # Default feedback for execution steps
      RLM.Prompt.build_feedback_message(
        ctx.truncated_output,
        ctx.eval_status,
        ctx.bindings_info,
        ctx.final_answer != nil
      )
    end

    def check_completion(_strategy, bindings, _ctx) do
      cond do
        Keyword.get(bindings, :final_answer) != nil ->
          {:stop, {:ok, Keyword.get(bindings, :final_answer)}}
        Keyword.get(bindings, :plan_failed) ->
          {:stop, {:error, "Plan execution failed"}}
        true ->
          :continue
      end
    end

    def between_iterations(_strategy, _history, _prev_codes), do: nil
  end
end
```

## Files to Create

| File | Purpose |
|---|---|
| `lib/rlm/strategy.ex` | Protocol definition |
| `lib/rlm/strategy/default.ex` | Default implementation (extracts current Worker logic) |
| `test/rlm/strategy_test.exs` | Protocol + default strategy tests |

## Files to Modify

| File | Change |
|---|---|
| `lib/rlm/worker.ex` | Add `:strategy` to struct; replace inline decision logic with protocol calls |
| `lib/rlm/config.ex` | Add `:strategy` field |

## Test Plan

```elixir
defmodule RLM.StrategyTest do
  use ExUnit.Case, async: true
  alias RLM.Strategy
  alias RLM.Strategy.Default

  describe "Default strategy" do
    test "build_feedback returns structured JSON for success" do
      ctx = %{
        eval_status: :ok,
        truncated_output: "hello",
        bindings_info: [],
        final_answer: nil,
        code: "IO.puts(:hi)",
        iteration: 0
      }
      msg = Strategy.build_feedback(%Default{}, ctx)
      assert msg.role == :user
      assert Jason.decode!(msg.content)["eval_status"] == "ok"
    end

    test "check_completion returns :continue when no final_answer" do
      assert :continue == Strategy.check_completion(
        %Default{},
        [final_answer: nil, x: 1],
        %{}
      )
    end

    test "check_completion returns {:stop, {:ok, answer}} when final_answer set" do
      assert {:stop, {:ok, 42}} == Strategy.check_completion(
        %Default{},
        [final_answer: 42],
        %{}
      )
    end

    test "between_iterations returns nil when codes differ" do
      assert nil == Strategy.between_iterations(
        %Default{},
        [],
        ["code_a", "code_b", "code_c"]
      )
    end

    test "between_iterations returns nudge when codes are similar" do
      same = "x = Enum.map(data, &process/1)"
      result = Strategy.between_iterations(%Default{}, [], [same, same, same])
      assert is_list(result)
      assert length(result) == 1
    end
  end
end

# Integration test: Worker uses strategy
defmodule RLM.Worker.StrategyIntegrationTest do
  use ExUnit.Case, async: false  # MockLLM
  alias RLM.Test.{MockLLM, Helpers}

  test "worker uses default strategy by default" do
    MockLLM.program_responses([
      MockLLM.mock_response(~s(final_answer = "works"))
    ])

    %{run_pid: run_pid, config: config} = Helpers.start_test_run([])

    {:ok, pid} = RLM.Run.start_worker(run_pid, [
      context: "test",
      config: config,
      caller: self()
    ])

    assert_receive {:rlm_result, _, {:ok, "works"}}, 5_000
  end

  test "worker accepts custom strategy" do
    # Custom strategy that considers any non-nil binding :done as completion
    defmodule DoneStrategy do
      defstruct []
      defimpl RLM.Strategy do
        def build_feedback(_, ctx), do: RLM.Strategy.Default |> struct() |> RLM.Strategy.build_feedback(ctx)
        def check_completion(_, bindings, _) do
          if Keyword.get(bindings, :done), do: {:stop, {:ok, Keyword.get(bindings, :done)}}, else: :continue
        end
        def between_iterations(_, _, _), do: nil
      end
    end

    MockLLM.program_responses([
      MockLLM.mock_response(~s(done = "finished"))
    ])

    %{run_pid: run_pid, config: config} = Helpers.start_test_run([])

    {:ok, _pid} = RLM.Run.start_worker(run_pid, [
      context: "test",
      config: config,
      caller: self(),
      strategy: %DoneStrategy{}
    ])

    assert_receive {:rlm_result, _, {:ok, "finished"}}, 5_000
  end
end
```

## Migration Notes

The refactoring of Worker must be precise. The current decision logic lives in:

- `handle_eval_complete/2` lines 521-637 — feedback building + final_answer check
- `handle_eval_crash/2` lines 640-677 — error feedback building
- `maybe_nudge/1` lines 891-898 — nudge detection
- `codes_similar?/1` lines 900-904 — similarity check
- `similarity/2` lines 906-912 — Jaccard similarity

After refactoring, `maybe_nudge/1`, `codes_similar?/1`, and `similarity/2` move to
`Strategy.Default`. The Worker's `handle_eval_complete/2` and `handle_eval_crash/2`
become thinner — they prepare the `eval_ctx` map and delegate to the protocol.

## Documentation Updates

- **CLAUDE.md Module Map**: Add rows for `RLM.Strategy`, `RLM.Strategy.Default`
- **CLAUDE.md Config Fields**: Add `strategy` row
- **CHANGELOG.md**: Entry under `Added`

## Verification

```bash
mix compile --warnings-as-errors
mix test
mix format --check-formatted
mix docs
```

## Design Rationale

- **Protocol, not behaviour**: Protocols dispatch on the strategy struct's type, giving
  us polymorphism without dynamic dispatch tables. A custom strategy is just a struct +
  protocol implementation — no registration needed.
- **eval_ctx map, not Worker state**: The protocol receives a curated context map, not
  the full Worker state. This keeps the protocol's surface area small and prevents
  strategies from depending on Worker internals.
- **Default preserves exact behavior**: The refactoring is a strict extract — the
  Default strategy produces identical feedback messages, identical completion checks,
  and identical nudge detection. Existing tests pass without modification.
- **Strategy is per-worker, not global**: Passed via opts, stored in Worker struct.
  Different workers in the same run can use different strategies (e.g., parent uses
  PlanFirst, children use Default).
