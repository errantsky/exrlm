defmodule RLM.Tools.Grep do
  @moduledoc "Search file contents using ripgrep, with glob filtering."

  @behaviour RLM.Tool

  @max_results 200

  @impl true
  def name, do: :grep_files

  @impl true
  def doc do
    """
    grep_files(pattern, opts \\\\ [])

    Search for a pattern in files using ripgrep. Returns matching lines
    with file path and line number. Results capped at 200 matches.

    ## Options

      - :path — file or directory to search in (default: ".")
      - :glob — glob pattern to filter files, e.g. "*.ex" or "**/*.exs"
      - :case_insensitive — case-insensitive search (default: false)

    ## Examples

        grep_files("defmodule")
        grep_files("TODO", path: "lib/", glob: "*.ex")
        grep_files("error", case_insensitive: true)
    """
  end

  @spec execute(String.t(), keyword()) :: {:ok, String.t()} | {:error, String.t()}
  def execute(pattern, opts \\ []) do
    path = Keyword.get(opts, :path, ".")
    glob = Keyword.get(opts, :glob)
    case_insensitive = Keyword.get(opts, :case_insensitive, false)

    args =
      ["--line-number", "--no-heading"]
      |> maybe_add("-i", case_insensitive)
      |> maybe_add(["--glob", glob], !is_nil(glob))
      |> Enum.concat([pattern, path])

    case System.cmd("rg", args, stderr_to_stdout: true) do
      {output, 0} ->
        lines = String.split(output, "\n", trim: true)

        result =
          if length(lines) > @max_results do
            capped = lines |> Enum.take(@max_results) |> Enum.join("\n")
            capped <> "\n[Results truncated: showing #{@max_results} of #{length(lines)} total matches]"
          else
            output
          end

        {:ok, result}

      {_output, 1} ->
        {:ok, "No matches found"}

      {output, _exit_code} ->
        {:error, "grep error: #{output}"}
    end
  rescue
    e in ErlangError ->
      if e.original == :enoent do
        execute_fallback(pattern, opts)
      else
        {:error, "Search failed: #{Exception.message(e)}"}
      end
  end

  defp execute_fallback(pattern, opts) do
    path = Keyword.get(opts, :path, ".")
    case_insensitive = Keyword.get(opts, :case_insensitive, false)

    args =
      ["-r", "-n", "--include=*.{ex,exs}"]
      |> maybe_add("-i", case_insensitive)
      |> Enum.concat([pattern, path])

    case System.cmd("grep", args, stderr_to_stdout: true) do
      {output, 0} -> {:ok, output}
      {_, 1} -> {:ok, "No matches found"}
      {output, _} -> {:error, "grep error: #{output}"}
    end
  end

  defp maybe_add(args, _flag, false), do: args
  defp maybe_add(args, flag, true) when is_binary(flag), do: args ++ [flag]
  defp maybe_add(args, flags, true) when is_list(flags), do: args ++ flags
end
