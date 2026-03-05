# Plan: Dynamic Tool Registry with Schema Validation

## Motivation

The current `RLM.ToolRegistry` has a hardcoded `@tools` list. Adding a tool requires editing
the registry module. Tools have no input schema — bad params produce runtime crashes caught
only by the `try/rescue` in `execute/2`.

Jido Actions have compile-time schema validation via NimbleOptions. We can adopt the useful
part — **declarative input schemas on tools** — without the framework weight. This gives us:

1. **Extensibility**: Users add tools via config, not source edits
2. **Validation**: Bad inputs are rejected with clear errors before execution
3. **Introspection**: The LLM system prompt can include parameter schemas automatically
4. **Auto-generated sandbox wrappers**: New tools appear in eval'd code without manual
   wrapper functions in `RLM.Sandbox`

## Design

### Extend `RLM.Tool` Behaviour

Add an optional `schema/0` callback:

```elixir
defmodule RLM.Tool do
  @type input :: map()
  @type result :: {:ok, String.t()} | {:error, String.t()}

  @callback name() :: String.t()
  @callback description() :: String.t()
  @callback schema() :: map()          # JSON Schema for input validation
  @callback execute(input()) :: result()

  @optional_callbacks [schema: 0]

  defmacro __using__(_opts) do
    quote do
      @behaviour RLM.Tool

      # Default: no schema (backwards compatible)
      def schema, do: %{}
      defoverridable schema: 0
    end
  end
end
```

### Refactor `RLM.ToolRegistry`

Replace the compile-time `@tools` module attribute with a runtime resolution that merges
built-in tools with configured extras:

```elixir
defmodule RLM.ToolRegistry do
  @builtin_tools [
    RLM.Tools.ReadFile,
    RLM.Tools.WriteFile,
    RLM.Tools.EditFile,
    RLM.Tools.Bash,
    RLM.Tools.Grep,
    RLM.Tools.Glob,
    RLM.Tools.Ls
  ]

  @doc "All registered tool modules (built-in + configured extras)."
  @spec all() :: [module()]
  def all do
    extras = Application.get_env(:rlm, :extra_tools, [])
    @builtin_tools ++ extras
  end

  @doc "List of tool name strings."
  @spec names() :: [String.t()]
  def names, do: Enum.map(all(), & &1.name())

  @doc "List of `{name, description}` tuples for all tools."
  @spec descriptions() :: [{String.t(), String.t()}]
  def descriptions, do: Enum.map(all(), &{&1.name(), &1.description()})

  @doc "List of `{name, description, schema}` tuples for all tools."
  @spec descriptions_with_schemas() :: [{String.t(), String.t(), map()}]
  def descriptions_with_schemas do
    Enum.map(all(), fn mod ->
      schema = if function_exported?(mod, :schema, 0), do: mod.schema(), else: %{}
      {mod.name(), mod.description(), schema}
    end)
  end

  @doc "Execute a tool by name with input validation."
  @spec execute(String.t(), map()) :: {:ok, String.t()} | {:error, String.t()}
  def execute(name, input) do
    case find_tool(name) do
      nil ->
        {:error, "Unknown tool: #{name}"}

      mod ->
        schema = if function_exported?(mod, :schema, 0), do: mod.schema(), else: %{}

        case validate_input(input, schema) do
          :ok ->
            try do
              mod.execute(input)
            rescue
              e -> {:error, "Tool #{name} raised: #{Exception.message(e)}"}
            end

          {:error, reasons} ->
            {:error, "Invalid input for #{name}: #{Enum.join(reasons, "; ")}"}
        end
    end
  end

  @doc "Look up description for a single tool by name."
  @spec description_for(String.t()) :: {:ok, String.t()} | {:error, :not_found}
  def description_for(name) do
    case find_tool(name) do
      nil -> {:error, :not_found}
      mod -> {:ok, mod.description()}
    end
  end

  defp find_tool(name), do: Enum.find(all(), fn mod -> mod.name() == name end)

  # Lightweight JSON Schema validation (same approach as MockLLM)
  defp validate_input(_input, schema) when schema == %{}, do: :ok

  defp validate_input(input, schema) do
    errors = do_validate(input, schema, [])
    if errors == [], do: :ok, else: {:error, Enum.reverse(errors)}
  end

  defp do_validate(data, schema, errors) do
    errors
    |> check_required(data, schema)
    |> check_types(data, schema)
  end

  defp check_required(errors, data, %{"required" => keys}) when is_map(data) do
    Enum.reduce(keys, errors, fn key, acc ->
      if Map.has_key?(data, key), do: acc, else: ["missing required param: #{key}" | acc]
    end)
  end
  defp check_required(errors, _data, _schema), do: errors

  defp check_types(errors, data, %{"properties" => props}) when is_map(data) do
    Enum.reduce(props, errors, fn {key, prop_schema}, acc ->
      case Map.fetch(data, key) do
        {:ok, value} ->
          expected = Map.get(prop_schema, "type")
          if expected && !type_matches?(value, expected),
            do: ["#{key}: expected #{expected}, got #{inspect(value)}" | acc],
            else: acc
        :error -> acc
      end
    end)
  end
  defp check_types(errors, _data, _schema), do: errors

  defp type_matches?(v, "string") when is_binary(v), do: true
  defp type_matches?(v, "integer") when is_integer(v), do: true
  defp type_matches?(v, "number") when is_number(v), do: true
  defp type_matches?(v, "boolean") when is_boolean(v), do: true
  defp type_matches?(_, _), do: false
end
```

### Add Schemas to Existing Tools

Add `schema/0` to each built-in tool. Example for `ReadFile`:

```elixir
defmodule RLM.Tools.ReadFile do
  use RLM.Tool

  @impl true
  def name, do: "read_file"

  @impl true
  def description, do: "Read the contents of a file (up to 100 KB)."

  @impl true
  def schema do
    %{
      "required" => ["path"],
      "properties" => %{
        "path" => %{"type" => "string", "description" => "Absolute or relative file path"}
      }
    }
  end

  @impl true
  def execute(%{"path" => path}) do
    # ... existing implementation unchanged
  end
end
```

Apply the same pattern to all 7 built-in tools. Each schema simply declares the
params the tool already expects — no behavioral change.

### Auto-Generate Sandbox Wrappers

Add a function to `RLM.Sandbox` that generates wrapper functions for extra tools
at runtime. Since eval'd code runs `import RLM.Sandbox`, new tools need to be
callable by name.

Rather than generating functions dynamically (which would be fragile), add a
generic `tool/2` function:

```elixir
# In RLM.Sandbox — add to existing module
@doc "Call any registered tool by name. For tools beyond the built-in wrappers."
def tool(name, input) when is_binary(name) and is_map(input) do
  input = resolve_paths_in_input(input)
  RLM.ToolRegistry.execute(name, input)
end

defp resolve_paths_in_input(input) do
  Enum.reduce(["path", "base", "cwd"], input, fn key, acc ->
    case Map.get(acc, key) do
      nil -> acc
      path -> Map.put(acc, key, resolve(path))
    end
  end)
end
```

This lets eval'd code call `tool("my_custom_tool", %{"query" => "something"})`.

### Update System Prompt

Modify `RLM.Prompt` to include tool schemas in the system prompt automatically:

```elixir
# In RLM.Prompt — add helper
defp tool_documentation do
  RLM.ToolRegistry.descriptions_with_schemas()
  |> Enum.map_join("\n", fn {name, desc, schema} ->
    params = format_schema_params(schema)
    "- `#{name}` — #{desc}#{params}"
  end)
end

defp format_schema_params(%{"properties" => props, "required" => req}) do
  params = Enum.map_join(props, ", ", fn {name, spec} ->
    type = Map.get(spec, "type", "any")
    required? = name in req
    if required?, do: "#{name}: #{type}", else: "#{name}: #{type} (optional)"
  end)
  "\n  Params: #{params}"
end
defp format_schema_params(_), do: ""
```

## Files to Modify

| File | Change |
|---|---|
| `lib/rlm/tool.ex` | Add `schema/0` callback + optional_callbacks + default in `__using__` |
| `lib/rlm/tool_registry.ex` | Runtime `all/0`, input validation, `descriptions_with_schemas/0` |
| `lib/rlm/tools/read_file.ex` | Add `schema/0` |
| `lib/rlm/tools/write_file.ex` | Add `schema/0` |
| `lib/rlm/tools/edit_file.ex` | Add `schema/0` |
| `lib/rlm/tools/bash.ex` | Add `schema/0` |
| `lib/rlm/tools/grep.ex` | Add `schema/0` |
| `lib/rlm/tools/glob.ex` | Add `schema/0` |
| `lib/rlm/tools/ls.ex` | Add `schema/0` |
| `lib/rlm/sandbox.ex` | Add generic `tool/2` function |

## Files to Create

| File | Purpose |
|---|---|
| `test/rlm/tool_registry_test.exs` | Tests for validation, extra_tools, descriptions_with_schemas |

## Test Plan

```elixir
defmodule RLM.ToolRegistryTest do
  use ExUnit.Case, async: true

  test "all/0 returns built-in tools" do
    tools = RLM.ToolRegistry.all()
    assert length(tools) >= 7
    assert RLM.Tools.ReadFile in tools
  end

  test "all/0 includes extra tools from config" do
    # Use Application.put_env in setup, restore in on_exit
    Application.put_env(:rlm, :extra_tools, [FakeTestTool])
    on_exit(fn -> Application.delete_env(:rlm, :extra_tools) end)

    assert FakeTestTool in RLM.ToolRegistry.all()
  end

  test "execute/2 validates required params" do
    {:error, msg} = RLM.ToolRegistry.execute("read_file", %{})
    assert msg =~ "missing required param: path"
  end

  test "execute/2 validates param types" do
    {:error, msg} = RLM.ToolRegistry.execute("read_file", %{"path" => 123})
    assert msg =~ "expected string"
  end

  test "execute/2 passes valid input through" do
    # Write a temp file, read it back
    path = Path.join(System.tmp_dir!(), "registry_test_#{:rand.uniform(100000)}.txt")
    File.write!(path, "hello")
    on_exit(fn -> File.rm(path) end)

    {:ok, content} = RLM.ToolRegistry.execute("read_file", %{"path" => path})
    assert content =~ "hello"
  end

  test "descriptions_with_schemas/0 includes schemas" do
    result = RLM.ToolRegistry.descriptions_with_schemas()
    {_name, _desc, schema} = Enum.find(result, fn {n, _, _} -> n == "read_file" end)
    assert schema["required"] == ["path"]
  end
end
```

## Documentation Updates

- **CLAUDE.md Module Map**: No new modules, but note schema callback in Tool description
- **CLAUDE.md Config Fields**: Add `extra_tools` row
- **CHANGELOG.md**: Entry under `Added`

## Verification

```bash
mix compile --warnings-as-errors
mix test test/rlm/tool_registry_test.exs
mix test
mix format --check-formatted
mix docs
```

## Design Rationale

- **`all/0` reads config at runtime, not compile time**: The `@tools` module attribute
  is evaluated at compile time. Switching to `Application.get_env` in `all/0` lets users
  register tools without recompiling. The built-in list remains a compile-time constant
  for fast concat.
- **Schema is optional**: Existing tools work without implementing `schema/0` thanks to
  `defoverridable` default. No breaking change.
- **Generic `tool/2` over dynamic function generation**: Generating `def my_tool(args)`
  at runtime would require `Module.create` or macro tricks. A generic `tool(name, input)`
  function is simpler, discoverable, and doesn't pollute the sandbox namespace.
- **Validation reuses MockLLM's pattern**: The lightweight JSON Schema checking approach
  already exists in `test/support/mock_llm.ex`. We bring the same pattern to production
  code, keeping it simple (type + required checks, no `$ref` or `oneOf`).
