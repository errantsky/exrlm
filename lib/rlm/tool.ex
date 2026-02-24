defmodule RLM.Tool do
  @moduledoc """
  Behaviour for RLM filesystem tools.

  Each tool module must implement:
  - `name/0` — short identifier string (e.g. "read_file")
  - `description/0` — human-readable help text
  - `execute/1` — runs the tool given a params map

  ## Adding a new tool

  1. Create `lib/rlm/tools/my_tool.ex`
  2. `use RLM.Tool` and implement the three callbacks
  3. Register it in `RLM.ToolRegistry`
  """

  @type input :: map()
  @type result :: {:ok, String.t()} | {:error, String.t()}

  @callback name() :: String.t()
  @callback description() :: String.t()
  @callback execute(input()) :: result()

  defmacro __using__(_opts) do
    quote do
      @behaviour RLM.Tool
    end
  end
end
