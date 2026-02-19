defmodule RLM.Agent.Tools.Glob do
  use RLM.Agent.Tool

  @max_results 500

  @impl true
  def spec do
    %{
      "name" => "glob",
      "description" =>
        "Find files matching a glob pattern. Returns file paths sorted by modification time.",
      "input_schema" => %{
        "type" => "object",
        "properties" => %{
          "pattern" => %{
            "type" => "string",
            "description" => "Glob pattern, e.g. '**/*.ex' or 'lib/**/*.exs'"
          },
          "base" => %{
            "type" => "string",
            "description" => "Base directory for the search (default: current directory)"
          }
        },
        "required" => ["pattern"]
      }
    }
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
