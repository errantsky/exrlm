defmodule RLM.Tools.Grep do
  @moduledoc "Search for a pattern in files using ripgrep."
  use RLM.Tool

  @max_results 200

  @impl true
  def name, do: "grep"

  @impl true
  def description do
    "Search for a regex pattern in files using ripgrep. " <>
      "Returns matching lines with file path and line number."
  end

  @impl true
  def execute(%{"pattern" => pattern} = input) do
    path = Map.get(input, "path", ".")
    glob = Map.get(input, "glob")
    case_insensitive = Map.get(input, "case_insensitive", false)

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

            capped <>
              "\n[Results truncated: showing #{@max_results} of #{length(lines)} total matches]"
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
        execute_fallback(input)
      else
        {:error, "Search failed: #{Exception.message(e)}"}
      end
  end

  defp execute_fallback(%{"pattern" => pattern} = input) do
    path = Map.get(input, "path", ".")
    case_insensitive = Map.get(input, "case_insensitive", false)

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
