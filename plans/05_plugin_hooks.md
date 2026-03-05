# Plan: Plugin Hooks

## Motivation

RLM has rich telemetry instrumentation — events fire at every iteration, LLM call, eval,
subcall, and compaction boundary. But telemetry is observe-only. You can log, you can
broadcast, but you can't **intercept** or **modify** behavior.

Real-world needs that require interception:
- **Cost guard**: Abort before an LLM call if estimated cost exceeds a budget
- **Rate limiting**: Throttle LLM calls per minute
- **Audit log**: Record every eval'd code block to an external system before execution
- **Content filter**: Reject LLM responses that match dangerous patterns before eval
- **Custom compaction**: Replace the default history compaction with a summarization approach

Jido's plugin system has 8 callbacks, isolated state namespaces, compile-time validation,
and bus subscriptions. That's too much. We need the useful part: **a pipeline of hooks
at key decision points** with `:cont | {:halt, reason}` semantics.

## Design

### `RLM.Plugin` Behaviour

```elixir
defmodule RLM.Plugin do
  @moduledoc """
  Behaviour for RLM lifecycle hooks.

  Plugins are called in order at key decision points in the Worker iterate loop.
  Each callback returns `:cont` to proceed or `{:halt, reason}` to abort.

  All callbacks are optional. Implement only the hooks you need.
  """

  @type hook_result :: :cont | {:halt, String.t()}
  @type transform_result :: {:ok, any()} | {:halt, String.t()}

  @doc "Called before each LLM API call. Receives the message history and config."
  @callback before_llm(messages :: [map()], config :: RLM.Config.t()) :: hook_result()

  @doc "Called after LLM response, before eval. Can inspect or reject the response."
  @callback after_llm(response :: String.t(), reasoning :: String.t(), code :: String.t(), config :: RLM.Config.t()) :: hook_result()

  @doc "Called before code evaluation. Can inspect or reject the code."
  @callback before_eval(code :: String.t(), bindings :: keyword(), config :: RLM.Config.t()) :: hook_result()

  @doc "Called after eval completes. Receives the result."
  @callback after_eval(result :: {:ok | :error, String.t()}, bindings :: keyword(), config :: RLM.Config.t()) :: hook_result()

  @doc "Called when a run completes (success or failure)."
  @callback on_complete(result :: {:ok | :error, any()}, config :: RLM.Config.t()) :: :ok

  @optional_callbacks [
    before_llm: 2,
    after_llm: 4,
    before_eval: 3,
    after_eval: 3,
    on_complete: 2
  ]
end
```

### `RLM.Plugin.Pipeline`

A small module that runs a list of plugins through a hook:

```elixir
defmodule RLM.Plugin.Pipeline do
  @moduledoc """
  Runs a list of plugins through a named hook.
  Stops at the first `{:halt, reason}` and returns it.
  """

  @doc "Run all plugins through a hook. Returns :cont or {:halt, reason}."
  @spec run(hook :: atom(), args :: [any()], plugins :: [module()]) :: :cont | {:halt, String.t()}
  def run(hook, args, plugins) do
    Enum.reduce_while(plugins, :cont, fn plugin, :cont ->
      if function_exported?(plugin, hook, length(args)) do
        case apply(plugin, hook, args) do
          :cont -> {:cont, :cont}
          {:halt, reason} -> {:halt, {:halt, reason}}
        end
      else
        {:cont, :cont}
      end
    end)
  end

  @doc "Notify all plugins of an event (no halt semantics)."
  @spec notify(hook :: atom(), args :: [any()], plugins :: [module()]) :: :ok
  def notify(hook, args, plugins) do
    Enum.each(plugins, fn plugin ->
      if function_exported?(plugin, hook, length(args)) do
        apply(plugin, hook, args)
      end
    end)
  end
end
```

### Worker Integration

Add plugins to the Worker at four points:

**1. Before LLM call** (in `handle_info(:iterate)`, before `llm_module.chat`):

```elixir
case RLM.Plugin.Pipeline.run(:before_llm, [state.history, state.config], state.config.plugins) do
  :cont ->
    # proceed with LLM call
    case llm_module.chat(state.history, state.model, state.config) do
      # ...
    end

  {:halt, reason} ->
    complete(state, {:error, "Plugin halted before LLM: #{reason}"})
end
```

**2. After LLM response** (after `extract_structured`, before eval):

```elixir
case RLM.Plugin.Pipeline.run(:after_llm, [response, reasoning, code, state.config], state.config.plugins) do
  :cont ->
    if code != "" do
      start_async_eval(state, response, code, reasoning, llm_duration, usage, iter_start)
    else
      # ... empty code path
    end

  {:halt, reason} ->
    complete(state, {:error, "Plugin halted after LLM: #{reason}"})
end
```

**3. Before eval** (in `start_async_eval`, before spawning the task):

```elixir
case RLM.Plugin.Pipeline.run(:before_eval, [code, state.bindings, state.config], state.config.plugins) do
  :cont ->
    task = Task.Supervisor.async_nolink(state.eval_sup, fn -> ... end)
    # ...

  {:halt, reason} ->
    # Don't spawn eval, treat as error feedback
    feedback = RLM.Prompt.build_feedback_message(
      "Plugin blocked eval: #{reason}", :error,
      RLM.Helpers.list_bindings(state.bindings), false
    )
    state = %{state |
      history: state.history ++ [%{role: :assistant, content: response}, feedback],
      iteration: state.iteration + 1
    }
    send(self(), :iterate)
    {:noreply, state}
end
```

**4. After eval** (in `handle_eval_complete`):

```elixir
# After processing eval result, before checking completion
RLM.Plugin.Pipeline.run(:after_eval, [eval_result_tuple, state.bindings, state.config], state.config.plugins)
# Note: after_eval halt stops the run, it doesn't retry
```

**5. On completion** (in `complete/2`):

```elixir
RLM.Plugin.Pipeline.notify(:on_complete, [result, state.config], state.config.plugins)
```

### Config Integration

Add `:plugins` to `RLM.Config`:

```elixir
# In Config struct
:plugins

# In Config.load
plugins: get(overrides, :plugins, [])
```

### Example Plugins

**Cost Guard** (included in the codebase as a reference implementation):

```elixir
defmodule RLM.Plugins.CostGuard do
  @behaviour RLM.Plugin

  @impl true
  def before_llm(messages, config) do
    estimated_tokens = messages
    |> Enum.map(fn %{content: c} -> div(String.length(c), 4) end)
    |> Enum.sum()

    max_tokens = Map.get(config, :cost_guard_max_tokens, 100_000)

    if estimated_tokens > max_tokens do
      {:halt, "Estimated #{estimated_tokens} tokens exceeds limit of #{max_tokens}"}
    else
      :cont
    end
  end
end
```

**Code Blocklist** (example only, not shipped):

```elixir
defmodule RLM.Plugins.CodeBlocklist do
  @behaviour RLM.Plugin

  @blocked_patterns [
    ~r/System\.cmd/,
    ~r/File\.rm_rf/,
    ~r/:os\.cmd/
  ]

  @impl true
  def before_eval(code, _bindings, _config) do
    case Enum.find(@blocked_patterns, &Regex.match?(&1, code)) do
      nil -> :cont
      pattern -> {:halt, "Code contains blocked pattern: #{inspect(pattern)}"}
    end
  end
end
```

## Files to Create

| File | Purpose |
|---|---|
| `lib/rlm/plugin.ex` | Behaviour definition |
| `lib/rlm/plugin/pipeline.ex` | Pipeline runner (`run/3`, `notify/3`) |
| `lib/rlm/plugins/cost_guard.ex` | Reference plugin: token limit guard |
| `test/rlm/plugin/pipeline_test.exs` | Pipeline unit tests |
| `test/rlm/plugins/cost_guard_test.exs` | CostGuard unit tests |

## Files to Modify

| File | Change |
|---|---|
| `lib/rlm/worker.ex` | Add pipeline calls at 4 hook points |
| `lib/rlm/config.ex` | Add `:plugins` field (default `[]`) |

## Test Plan

```elixir
defmodule RLM.Plugin.PipelineTest do
  use ExUnit.Case, async: true
  alias RLM.Plugin.Pipeline

  defmodule PassPlugin do
    @behaviour RLM.Plugin
    @impl true
    def before_llm(_messages, _config), do: :cont
  end

  defmodule BlockPlugin do
    @behaviour RLM.Plugin
    @impl true
    def before_llm(_messages, _config), do: {:halt, "blocked"}
  end

  defmodule NoHookPlugin do
    @behaviour RLM.Plugin
    # Implements no optional callbacks
  end

  test "empty plugin list returns :cont" do
    assert :cont == Pipeline.run(:before_llm, [[], %{}], [])
  end

  test "all-pass plugins return :cont" do
    assert :cont == Pipeline.run(:before_llm, [[], %{}], [PassPlugin, PassPlugin])
  end

  test "first halt stops the pipeline" do
    assert {:halt, "blocked"} == Pipeline.run(:before_llm, [[], %{}], [PassPlugin, BlockPlugin, PassPlugin])
  end

  test "plugins without the hook are skipped" do
    assert :cont == Pipeline.run(:before_llm, [[], %{}], [NoHookPlugin, PassPlugin])
  end

  test "notify calls all plugins without halt semantics" do
    # Just verify it doesn't crash
    assert :ok == Pipeline.notify(:on_complete, [{:ok, "done"}, %{}], [PassPlugin, NoHookPlugin])
  end
end
```

Integration test (async: false due to MockLLM):

```elixir
defmodule RLM.Worker.PluginIntegrationTest do
  use ExUnit.Case, async: false
  alias RLM.Test.{MockLLM, Helpers}

  defmodule HaltBeforeLLM do
    @behaviour RLM.Plugin
    @impl true
    def before_llm(_messages, _config), do: {:halt, "cost exceeded"}
  end

  test "plugin can halt before LLM call" do
    # No need to program MockLLM responses — LLM should never be called
    %{run_pid: run_pid, config: config} = Helpers.start_test_run(
      config: RLM.Config.load(llm_module: MockLLM, plugins: [HaltBeforeLLM])
    )

    {:ok, _} = RLM.Run.start_worker(run_pid, [
      context: "test", config: config, caller: self()
    ])

    assert_receive {:rlm_result, _, {:error, "Plugin halted before LLM: cost exceeded"}}, 5_000
  end
end
```

## Documentation Updates

- **CLAUDE.md Module Map**: Add rows for `RLM.Plugin`, `RLM.Plugin.Pipeline`, `RLM.Plugins.CostGuard`
- **CLAUDE.md Config Fields**: Add `plugins` row
- **CHANGELOG.md**: Entry under `Added`

## Verification

```bash
mix compile --warnings-as-errors
mix test
mix format --check-formatted
mix docs
```

## Design Rationale

- **Behaviour, not protocol**: Plugins are module-based (not struct-based) because they
  have no instance state. A plugin is a collection of hook functions, not a data type.
  `function_exported?/3` handles optional callbacks naturally.
- **No plugin state isolation**: Jido gives each plugin its own state namespace. We skip
  this because RLM plugins are stateless interceptors, not stateful components. If a
  plugin needs state, it can use an Agent or ETS externally — that's an Elixir pattern,
  not a framework concern.
- **`:halt` stops the run, not just the iteration**: When a plugin halts, the Worker
  completes with an error. This is the safe default. A plugin that wants to skip an
  iteration (not abort the run) should modify the feedback message instead.
- **`notify/3` for completion**: The `on_complete` hook can't halt anything (the run
  is already done). Using `notify` instead of `run` makes this clear at the call site.
- **Plugins in config, not per-worker**: Plugins are set on `RLM.Config` so they apply
  uniformly. This could be extended to per-worker if needed, but global is the right
  starting point.
