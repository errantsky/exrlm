defmodule RLM.Agent.Prompt do
  @moduledoc """
  Builds the coding agent's system prompt.

  The prompt is composable: `build/1` accepts keyword opts to inject
  context such as the working directory, allowed tool names, and
  additional constraints.
  """

  @doc """
  Build the system prompt string.

  Options:
    - `:cwd`   — working directory shown to the agent (default: `File.cwd!/0`)
    - `:extra` — additional instructions appended at the end
  """
  @spec build(keyword()) :: String.t()
  def build(opts \\ []) do
    cwd = Keyword.get(opts, :cwd, cwd())
    extra = Keyword.get(opts, :extra, nil)

    base = """
    #{soul()}

    You are an expert Elixir coding agent. You help users understand and modify
    codebases by reading files, writing code, running commands, and reasoning about
    the results.

    ## Working directory

    #{cwd}

    ## Guidelines

    - Always read a file before editing it so you have complete context.
    - Prefer making small, targeted edits over rewriting entire files.
    - When running bash commands, prefer read-only commands first (ls, cat, grep).
    - Explain your reasoning briefly before each action.
    - After making changes, verify them (e.g. run the tests, check compilation).
    - If a task is ambiguous, ask a clarifying question before taking action.

    ## Tool usage

    Use `read_file` → `edit_file` for targeted changes.
    Use `write_file` only for new files or complete rewrites.
    Use `bash` for compilation, tests, and operations without a dedicated tool.
    Use `rlm_query` to analyse large data sets or files via the RLM code-eval engine.

    ## Elixir conventions

    - Run `mix format` after writing or editing Elixir files.
    - Run `mix compile` to check for errors before declaring a task done.
    - Prefer pattern matching and `with` over nested `case` chains.
    """

    if extra do
      base <> "\n## Additional instructions\n\n#{extra}\n"
    else
      base
    end
  end

  defp soul do
    path = Application.app_dir(:rlm, "priv/soul.md")

    case File.read(path) do
      {:ok, content} -> String.trim(content)
      {:error, _} -> ""
    end
  end

  defp cwd do
    case File.cwd() do
      {:ok, dir} -> dir
      _ -> "unknown"
    end
  end
end
