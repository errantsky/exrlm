defmodule RLM.Sandbox do
  @moduledoc """
  Functions available inside eval'd code.

  Provides data-processing helpers, LLM sub-call capabilities,
  file/shell/search tools, and runtime tool discovery.
  """

  # ---------------------------------------------------------------------------
  # Data helpers
  # ---------------------------------------------------------------------------

  defdelegate chunks(string, size), to: RLM.Helpers
  defdelegate grep(pattern, string), to: RLM.Helpers
  defdelegate preview(term, n \\ 500), to: RLM.Helpers

  @doc "List current bindings with their names, types, and sizes."
  def list_bindings do
    Process.get(:rlm_bindings_info, [])
  end

  # ---------------------------------------------------------------------------
  # LLM sub-calls
  # ---------------------------------------------------------------------------

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
  # File tools
  # ---------------------------------------------------------------------------

  @doc "Read file contents (max 100KB). Raises on error."
  def read_file(path), do: unwrap!(RLM.Tools.ReadFile.execute(path))

  @doc "Write content to a file, creating parent directories as needed. Raises on error."
  def write_file(path, content), do: unwrap!(RLM.Tools.WriteFile.execute(path, content))

  @doc "Replace an exact, unique string in a file. Raises on error."
  def edit_file(path, old_string, new_string),
    do: unwrap!(RLM.Tools.EditFile.execute(path, old_string, new_string))

  # ---------------------------------------------------------------------------
  # Shell and search tools
  # ---------------------------------------------------------------------------

  @doc "Run a bash command. Returns stdout. Raises on non-zero exit or timeout."
  def bash(command, opts \\ []), do: unwrap!(RLM.Tools.Bash.execute(command, opts))

  @doc "Search files with ripgrep. Returns matching lines. Raises on error."
  def grep_files(pattern, opts \\ []), do: unwrap!(RLM.Tools.Grep.execute(pattern, opts))

  @doc "Find files by glob pattern. Returns newline-separated paths. Raises on error."
  def glob(pattern, opts \\ []), do: unwrap!(RLM.Tools.Glob.execute(pattern, opts))

  @doc "List directory contents with sizes. Raises on error."
  def ls(path \\ "."), do: unwrap!(RLM.Tools.Ls.execute(path))

  # ---------------------------------------------------------------------------
  # Tool discovery
  # ---------------------------------------------------------------------------

  @doc "List all available tools with one-line summaries."
  def list_tools do
    RLM.Tools.Registry.list()
    |> Enum.map_join("\n", fn {name, summary} -> "  #{name} — #{summary}" end)
  end

  @doc "Show detailed usage, options, and examples for a tool."
  def tool_help(name) when is_atom(name) do
    case RLM.Tools.Registry.doc(name) do
      nil -> "Unknown tool: #{name}. Use list_tools() to see available tools."
      doc -> doc
    end
  end

  # ---------------------------------------------------------------------------
  # Internal
  # ---------------------------------------------------------------------------

  defp unwrap!({:ok, value}), do: value
  defp unwrap!({:error, msg}), do: raise(msg)
end
