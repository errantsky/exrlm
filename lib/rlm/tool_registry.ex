defmodule RLM.ToolRegistry do
  @moduledoc """
  Central registry of all available RLM tools.

  Provides:
  - `all/0` — list of all tool modules
  - `names/0` — list of tool name strings
  - `descriptions/0` — list of `{name, description}` tuples
  - `execute/2` — dispatch a tool call by name and input map
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

  @doc "All registered tool modules."
  @spec all() :: [module()]
  def all, do: @tools

  @doc "List of tool name strings."
  @spec names() :: [String.t()]
  def names, do: Enum.map(@tools, & &1.name())

  @doc "List of `{name, description}` tuples for all tools."
  @spec descriptions() :: [{String.t(), String.t()}]
  def descriptions, do: Enum.map(@tools, &{&1.name(), &1.description()})

  @doc """
  Execute a tool by name with the given input map.
  Returns `{:ok, output_string}` or `{:error, reason_string}`.
  """
  @spec execute(String.t(), map()) :: {:ok, String.t()} | {:error, String.t()}
  def execute(name, input) do
    case Enum.find(@tools, fn mod -> mod.name() == name end) do
      nil ->
        {:error, "Unknown tool: #{name}"}

      mod ->
        try do
          mod.execute(input)
        rescue
          e -> {:error, "Tool #{name} raised: #{Exception.message(e)}"}
        end
    end
  end

  @doc "Look up description for a single tool by name."
  @spec description_for(String.t()) :: {:ok, String.t()} | {:error, :not_found}
  def description_for(name) do
    case Enum.find(@tools, fn mod -> mod.name() == name end) do
      nil -> {:error, :not_found}
      mod -> {:ok, mod.description()}
    end
  end
end
