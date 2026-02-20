defmodule RLM.Sandbox do
  @moduledoc """
  Functions available inside eval'd code.
  Delegates helpers, provides LLM sub-call capabilities, and exposes
  filesystem tools for interactive sessions.
  """

  defdelegate chunks(string, size), to: RLM.Helpers
  defdelegate grep(pattern, string), to: RLM.Helpers
  defdelegate preview(term, n \\ 500), to: RLM.Helpers

  @doc "List current bindings with their names, types, and sizes."
  def list_bindings do
    Process.get(:rlm_bindings_info, [])
  end

  @doc """
  Invoke a sub-LLM on the given text. Blocks until the sub-call completes.
  Returns {:ok, response} or {:error, reason}.
  """
  def lm_query(text, opts \\ []) do
    worker_pid = Process.get(:rlm_worker_pid)

    if is_nil(worker_pid) do
      {:error, "lm_query not available (no worker context)"}
    else
      model_size = Keyword.get(opts, :model_size, :small)
      GenServer.call(worker_pid, {:spawn_subcall, text, model_size}, :infinity)
    end
  end

  @doc """
  Invoke multiple sub-LLMs concurrently. Returns results in order.
  Each item in `inputs` is {text, opts} or just text.
  """
  def parallel_query(inputs, default_opts \\ [model_size: :small]) do
    worker_pid = Process.get(:rlm_worker_pid)

    if is_nil(worker_pid) do
      Enum.map(inputs, fn _ -> {:error, "lm_query not available"} end)
    else
      inputs
      |> Enum.map(fn
        {text, opts} -> {text, opts}
        text when is_binary(text) -> {text, default_opts}
      end)
      |> Enum.map(fn {text, opts} ->
        Task.async(fn ->
          model_size = Keyword.get(opts, :model_size, :small)
          GenServer.call(worker_pid, {:spawn_subcall, text, model_size}, :infinity)
        end)
      end)
      |> Task.await_many(:infinity)
    end
  end

  # ---------------------------------------------------------------------------
  # Filesystem Tools
  # ---------------------------------------------------------------------------

  defp cwd, do: Process.get(:rlm_cwd, ".")

  @doc "Read the contents of a file (up to 100 KB)."
  def read_file(path) do
    RLM.Tools.ReadFile.execute(%{"path" => resolve(path)})
  end

  @doc "Write or overwrite a file. Creates parent directories as needed."
  def write_file(path, content) do
    RLM.Tools.WriteFile.execute(%{"path" => resolve(path), "content" => content})
  end

  @doc "Replace an exact string in a file. The old_string must be unique."
  def edit_file(path, old_string, new_string) do
    RLM.Tools.EditFile.execute(%{
      "path" => resolve(path),
      "old_string" => old_string,
      "new_string" => new_string
    })
  end

  @doc "Run a bash command. Returns {:ok, stdout} or {:error, reason}."
  def bash(command), do: bash(command, [])

  @doc """
  Run a bash command with options.

  Options:
    - `:timeout` — timeout in ms (default: 30_000, max: 300_000)
    - `:cwd` — working directory (default: session cwd)
  """
  def bash(command, opts) when is_list(opts) do
    input =
      %{"command" => command, "cwd" => Keyword.get(opts, :cwd, cwd())}
      |> maybe_put("timeout_ms", Keyword.get(opts, :timeout))

    RLM.Tools.Bash.execute(input)
  end

  @doc "Search for a regex pattern in files using ripgrep."
  def rg(pattern), do: rg(pattern, cwd(), [])

  @doc "Search for a regex pattern in files at the given path."
  def rg(pattern, path), do: rg(pattern, path, [])

  @doc """
  Search for a regex pattern in files using ripgrep.

  Options:
    - `:glob` — file glob filter (e.g. "*.ex")
    - `:case_insensitive` — case-insensitive search (default: false)
  """
  def rg(pattern, path, opts) when is_list(opts) do
    input =
      %{"pattern" => pattern, "path" => resolve(path)}
      |> maybe_put("glob", Keyword.get(opts, :glob))
      |> maybe_put("case_insensitive", Keyword.get(opts, :case_insensitive))

    RLM.Tools.Grep.execute(input)
  end

  @doc "Find files matching a glob pattern in the session working directory."
  def find_files(pattern), do: find_files(pattern, cwd())

  @doc "Find files matching a glob pattern in the given base directory."
  def find_files(pattern, base) do
    RLM.Tools.Glob.execute(%{"pattern" => pattern, "base" => resolve(base)})
  end

  @doc "List contents of the session working directory."
  def ls, do: ls(cwd())

  @doc "List contents of the given directory."
  def ls(path) do
    RLM.Tools.Ls.execute(%{"path" => resolve(path)})
  end

  @doc "List all available tool functions with descriptions."
  def list_tools do
    RLM.ToolRegistry.descriptions()
    |> Enum.map_join("\n", fn {name, desc} -> "  #{name} — #{desc}" end)
    |> then(&("Available tools:\n" <> &1))
  end

  @doc "Get the description for a specific tool by name."
  def tool_help(name) do
    case RLM.ToolRegistry.description_for(name) do
      {:ok, desc} -> "#{name}: #{desc}"
      {:error, :not_found} -> "Unknown tool: #{name}"
    end
  end

  # Resolve a path relative to the session cwd
  defp resolve(path) do
    if Path.type(path) == :absolute do
      path
    else
      Path.join(cwd(), path)
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
