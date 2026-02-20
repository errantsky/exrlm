defmodule RLM.Tools.Registry do
  @moduledoc """
  Central registry of all sandbox tools.

  Provides runtime introspection for `list_tools/0` and `tool_help/1`.
  """

  @tools [
    RLM.Tools.ReadFile,
    RLM.Tools.WriteFile,
    RLM.Tools.EditFile,
    RLM.Tools.Bash,
    RLM.Tools.Grep,
    RLM.Tools.Glob,
    RLM.Tools.Ls
  ]

  @doc "Return all tool modules."
  @spec all() :: [module()]
  def all, do: @tools

  @doc "Return `{name, one_line_summary}` for each tool."
  @spec list() :: [{atom(), String.t()}]
  def list do
    Enum.map(@tools, fn mod ->
      summary = mod.doc() |> String.split("\n", trim: true) |> hd()
      {mod.name(), summary}
    end)
  end

  @doc "Return the full doc string for a tool by name, or nil if not found."
  @spec doc(atom()) :: String.t() | nil
  def doc(name) do
    case Enum.find(@tools, fn mod -> mod.name() == name end) do
      nil -> nil
      mod -> mod.doc()
    end
  end
end
