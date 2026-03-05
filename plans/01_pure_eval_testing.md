# Plan: Pure Eval Testing (`RLM.Eval.Pure`)

## Motivation

Testing RLM logic currently requires spinning up the full GenServer stack: Run coordinator,
Worker, MockLLM, Task.Supervisor. This is necessary because `RLM.Sandbox` functions like
`lm_query/2` reach back into the Worker via `GenServer.call`, making eval inseparable from
the process infrastructure.

Jido's key insight is that decisions and effects can be separated. We can apply this narrowly:
let eval'd code run against a **recording sandbox** that captures side-effect calls as data
instead of executing them. This gives us pure-function testability for the code-evaluation
layer without touching the Worker/Run architecture.

## Design

### New Module: `RLM.Eval.Pure`

A single public function:

```elixir
RLM.Eval.Pure.run(code, bindings, opts \\ [])
# => {:ok, %RLM.Eval.Pure.Result{
#      stdout: "...",
#      bindings: [x: 42, final_answer: "done"],
#      calls: [
#        %{function: :lm_query, args: ["summarize this"], result: {:ok, "summary"}},
#        %{function: :read_file, args: ["/tmp/data.txt"], result: {:ok, "contents"}}
#      ],
#      value: "done"
#    }}
# => {:error, reason, original_bindings}
```

### New Module: `RLM.Sandbox.Pure`

A mirror of `RLM.Sandbox` where every side-effecting function is replaced with a
stub that:

1. Looks up a pre-programmed response from the process dictionary
2. Records the call (function name, args, result) into a process-dictionary accumulator
3. Returns the response

```elixir
defmodule RLM.Sandbox.Pure do
  # Helpers delegate normally — they're already pure
  defdelegate chunks(string, size), to: RLM.Helpers
  defdelegate grep(pattern, string), to: RLM.Helpers
  defdelegate preview(term, n \\ 500), to: RLM.Helpers

  def list_bindings do
    Process.get(:rlm_bindings_info, [])
  end

  # Side-effecting functions record + return stubs
  def lm_query(text, opts \\ []) do
    respond_and_record(:lm_query, [text, opts])
  end

  def parallel_query(inputs, opts \\ []) do
    Enum.map(inputs, fn
      {text, input_opts} -> respond_and_record(:lm_query, [text, input_opts])
      text -> respond_and_record(:lm_query, [text, opts])
    end)
  end

  def read_file(path),              do: respond_and_record(:read_file, [path])
  def write_file(path, content),    do: respond_and_record(:write_file, [path, content])
  def edit_file(path, old, new),    do: respond_and_record(:edit_file, [path, old, new])
  def bash(cmd),                    do: respond_and_record(:bash, [cmd])
  def bash(cmd, opts),              do: respond_and_record(:bash, [cmd, opts])
  def rg(pattern),                  do: respond_and_record(:rg, [pattern])
  def rg(pattern, path),            do: respond_and_record(:rg, [pattern, path])
  def rg(pattern, path, opts),      do: respond_and_record(:rg, [pattern, path, opts])
  def find_files(pattern),          do: respond_and_record(:find_files, [pattern])
  def find_files(pattern, base),    do: respond_and_record(:find_files, [pattern, base])
  def ls(),                         do: respond_and_record(:ls, [])
  def ls(path),                     do: respond_and_record(:ls, [path])
  def list_tools(),                 do: respond_and_record(:list_tools, [])
  def tool_help(name),              do: respond_and_record(:tool_help, [name])

  defp respond_and_record(function, args) do
    stubs = Process.get(:rlm_pure_stubs, %{})
    call_index = Process.get(:rlm_pure_call_index, 0)

    # Look up response: first by {function, call_index}, then by function name
    result = case Map.get(stubs, {function, call_index}) do
      nil -> Map.get(stubs, function, {:ok, "stub: #{function}"})
      val -> val
    end

    # Record the call
    calls = Process.get(:rlm_pure_calls, [])
    Process.put(:rlm_pure_calls, [{function, args, result} | calls])
    Process.put(:rlm_pure_call_index, call_index + 1)

    result
  end
end
```

### `RLM.Eval.Pure.run/3` Implementation

Reuses the same spawn-link + IO-capture pattern as `RLM.Eval.run/3`, but:

1. Imports `RLM.Sandbox.Pure` instead of `RLM.Sandbox`
2. Injects stub responses into process dictionary before eval
3. Collects recorded calls after eval
4. Returns a `%RLM.Eval.Pure.Result{}` struct

```elixir
defmodule RLM.Eval.Pure do
  defmodule Result do
    defstruct [:stdout, :bindings, :calls, :value]
  end

  def run(code, bindings, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 30_000)
    stubs = Keyword.get(opts, :stubs, %{})
    bindings_info = Keyword.get(opts, :bindings_info, [])
    caller = self()

    pid = spawn_link(fn ->
      {:ok, string_io} = StringIO.open("")
      Process.group_leader(self(), string_io)

      Process.put(:rlm_bindings_info, bindings_info)
      Process.put(:rlm_pure_stubs, stubs)
      Process.put(:rlm_pure_calls, [])
      Process.put(:rlm_pure_call_index, 0)

      wrapped = "import RLM.Sandbox.Pure\n#{code}"

      result = try do
        {value, new_bindings} = Code.eval_string(wrapped, bindings, file: "rlm_pure", line: 0)
        stdout = StringIO.flush(string_io)
        calls = Process.get(:rlm_pure_calls, []) |> Enum.reverse()
        {:ok, %Result{stdout: stdout, bindings: new_bindings, calls: calls, value: value}}
      rescue
        e ->
          stdout = StringIO.flush(string_io)
          {:error, "#{Exception.format(:error, e, __STACKTRACE__)}\n\nStdout:\n#{stdout}", bindings}
      catch
        kind, reason ->
          stdout = StringIO.flush(string_io)
          {:error, "#{Exception.format(kind, reason, __STACKTRACE__)}\n\nStdout:\n#{stdout}", bindings}
      end

      send(caller, {:pure_eval_result, self(), result})
    end)

    ref = Process.monitor(pid)

    receive do
      {:pure_eval_result, ^pid, result} ->
        Process.demonitor(ref, [:flush])
        result
      {:DOWN, ^ref, :process, ^pid, reason} ->
        {:error, "Pure eval crashed: #{inspect(reason)}", bindings}
    after
      timeout ->
        Process.exit(pid, :kill)
        Process.demonitor(ref, [:flush])
        receive do
          {:pure_eval_result, ^pid, _} -> :ok
          {:DOWN, ^ref, :process, ^pid, _} -> :ok
        after 100 -> :ok
        end
        {:error, "Pure eval timed out after #{timeout}ms", bindings}
    end
  end
end
```

## Files to Create

| File | Purpose |
|---|---|
| `lib/rlm/sandbox/pure.ex` | Recording sandbox — mirrors Sandbox API, captures calls as data |
| `lib/rlm/eval/pure.ex` | Pure eval runner + `Result` struct |
| `test/rlm/eval/pure_test.exs` | Tests for pure eval |

## Files to Modify

None. This is purely additive.

## Test Plan

All tests can run `async: true` since there's no global state.

```elixir
defmodule RLM.Eval.PureTest do
  use ExUnit.Case, async: true
  alias RLM.Eval.Pure

  test "evaluates simple code and returns bindings" do
    {:ok, result} = Pure.run("x = 1 + 2", [])
    assert result.bindings[:x] == 3
    assert result.calls == []
  end

  test "captures stdout" do
    {:ok, result} = Pure.run(~s(IO.puts("hello")), [])
    assert result.stdout =~ "hello"
  end

  test "records lm_query calls with stub responses" do
    {:ok, result} = Pure.run(
      ~s(answer = lm_query("summarize")),
      [],
      stubs: %{lm_query: {:ok, "summary"}}
    )
    assert result.bindings[:answer] == {:ok, "summary"}
    assert [{:lm_query, ["summarize", []], {:ok, "summary"}}] = result.calls
  end

  test "records tool calls" do
    {:ok, result} = Pure.run(
      ~s(data = read_file("/tmp/test.txt")),
      [],
      stubs: %{read_file: {:ok, "file contents"}}
    )
    assert result.bindings[:data] == {:ok, "file contents"}
    assert [{:read_file, ["/tmp/test.txt"], {:ok, "file contents"}}] = result.calls
  end

  test "preserves bindings across sequential calls" do
    {:ok, r1} = Pure.run("x = 10", [])
    {:ok, r2} = Pure.run("y = x * 2", r1.bindings)
    assert r2.bindings[:y] == 20
  end

  test "returns error on exception" do
    {:error, msg, _} = Pure.run("raise \"boom\"", [])
    assert msg =~ "boom"
  end

  test "detects final_answer" do
    {:ok, result} = Pure.run(~s(final_answer = "done"), [final_answer: nil])
    assert result.bindings[:final_answer] == "done"
  end

  test "indexed stubs for sequential calls" do
    {:ok, result} = Pure.run("""
      a = lm_query("first")
      b = lm_query("second")
    """, [],
      stubs: %{
        {:lm_query, 0} => {:ok, "first response"},
        {:lm_query, 1} => {:ok, "second response"}
      }
    )
    assert result.bindings[:a] == {:ok, "first response"}
    assert result.bindings[:b] == {:ok, "second response"}
    assert length(result.calls) == 2
  end

  test "pure helpers work normally" do
    {:ok, result} = Pure.run(~s(p = preview(%{a: 1, b: 2})), [])
    assert is_binary(result.bindings[:p])
  end
end
```

## Documentation Updates

- **CLAUDE.md Module Map**: Add rows for `RLM.Eval.Pure`, `RLM.Sandbox.Pure`
- **CHANGELOG.md**: Add entry under `## [Unreleased]` / `Added`

## Verification

```bash
mix compile --warnings-as-errors
mix test test/rlm/eval/pure_test.exs
mix test
mix format --check-formatted
mix docs
```

## Design Rationale

- **No changes to existing code**: `RLM.Eval` and `RLM.Sandbox` are untouched. The pure
  variants live alongside them as opt-in alternatives.
- **Process dictionary for stubs**: Matches the existing pattern in `RLM.Eval` where
  `worker_pid`, `cwd`, etc. are injected via process dict. Consistent, not novel.
- **Indexed stubs**: `{function, call_index}` keys let you program different responses
  for sequential calls to the same function, which is essential for testing multi-step
  code that calls `lm_query` multiple times.
- **Result struct**: Explicit struct instead of a bare tuple makes the return value
  self-documenting and extensible.
- **async: true**: No global state means parallel test execution. This is the whole point —
  you escape the MockLLM bottleneck for code-level tests.
