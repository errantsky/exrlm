defmodule RLM.Agent.ToolRegistry do
  @moduledoc """
  Central registry of all available coding agent tools.

  Provides:
  - `all/0` — list of all tool modules
  - `specs/0` — list of Anthropic API tool definition maps (for the LLM)
  - `execute/2` — dispatch a tool call by name and input map
  - `spec_for/1` — look up a single tool spec by name
  """

  @tools [
    RLM.Agent.Tools.ReadFile,
    RLM.Agent.Tools.WriteFile,
    RLM.Agent.Tools.EditFile,
    RLM.Agent.Tools.Bash,
    RLM.Agent.Tools.Grep,
    RLM.Agent.Tools.Glob,
    RLM.Agent.Tools.Ls,
    RLM.Agent.Tools.RlmQuery
  ]

  @doc "All registered tool modules."
  @spec all() :: [module()]
  def all, do: @tools

  @doc "Anthropic API tool spec maps for all registered tools."
  @spec specs() :: [map()]
  def specs, do: Enum.map(@tools, & &1.spec())

  @doc "Anthropic API tool spec for a single tool by name."
  @spec spec_for(String.t()) :: {:ok, map()} | {:error, :not_found}
  def spec_for(name) do
    case Enum.find(@tools, fn mod -> mod.name() == name end) do
      nil -> {:error, :not_found}
      mod -> {:ok, mod.spec()}
    end
  end

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
end
