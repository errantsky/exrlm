defmodule RLM.Tools.Glob do
  @moduledoc "Find files matching a glob pattern."
  use RLM.Tool

  @max_results 500

  @impl true
  def name, do: "glob"

  @impl true
  def description do
    "Find files matching a glob pattern (e.g. '**/*.ex'). " <>
      "Returns paths sorted by modification time, capped at #{@max_results}."
  end

  @impl true
  def execute(%{"pattern" => pattern} = input) do
    base = Map.get(input, "base", ".")
    full_pattern = Path.join(base, pattern)

    paths =
      full_pattern
      |> Path.wildcard()
      |> Enum.take(@max_results)

    if paths == [] do
      {:ok, "No files matched #{pattern}"}
    else
      suffix =
        if length(paths) >= @max_results,
          do: "\n[... truncated at #{@max_results} results]",
          else: ""

      {:ok, Enum.join(paths, "\n") <> suffix}
    end
  end
end
