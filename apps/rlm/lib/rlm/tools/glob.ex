defmodule RLM.Tools.Glob do
  @moduledoc "Find files matching a glob pattern."

  @behaviour RLM.Tool

  @max_results 500

  @impl true
  def name, do: :glob

  @impl true
  def doc do
    """
    glob(pattern, opts \\\\ [])

    Find files matching a glob pattern. Returns a newline-separated list
    of paths. Results capped at 500 matches.

    ## Options

      - :base — base directory for the search (default: ".")

    ## Examples

        glob("**/*.ex")
        glob("*.exs", base: "config/")
        glob("lib/**/*_test.exs")
    """
  end

  @spec execute(String.t(), keyword()) :: {:ok, String.t()} | {:error, String.t()}
  def execute(pattern, opts \\ []) do
    base = Keyword.get(opts, :base, ".")
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
