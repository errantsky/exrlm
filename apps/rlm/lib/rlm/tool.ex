defmodule RLM.Tool do
  @moduledoc """
  Behaviour for RLM sandbox tools.

  Each tool module implements `name/0` and `doc/0` for runtime discovery
  via `list_tools/0` and `tool_help/1` in the sandbox. The `execute` function
  has tool-specific arity and is called directly by `RLM.Sandbox` wrappers.
  """

  @callback name() :: atom()
  @callback doc() :: String.t()
end
