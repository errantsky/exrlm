defmodule RLM.Agent.Tool do
  @moduledoc """
  Behaviour for coding agent tools.

  Each tool module must:
  1. Implement `spec/0` — returns the Anthropic tool JSON schema map
  2. Implement `execute/1` — runs the tool given parsed input params
  3. (Optional) Expose `name/0` for convenience

  ## Adding a new tool

  1. Create `apps/rlm/lib/rlm/agent/tools/my_tool.ex`
  2. `use RLM.Agent.Tool` and implement `spec/0` and `execute/1`
  3. Register it in `RLM.Agent.ToolRegistry`

  ## Example

      defmodule RLM.Agent.Tools.Echo do
        use RLM.Agent.Tool

        @impl true
        def spec do
          %{
            "name" => "echo",
            "description" => "Echoes the input back",
            "input_schema" => %{
              "type" => "object",
              "properties" => %{
                "message" => %{"type" => "string"}
              },
              "required" => ["message"]
            }
          }
        end

        @impl true
        def execute(%{"message" => msg}), do: {:ok, msg}
      end
  """

  @type input :: map()
  @type result :: {:ok, String.t()} | {:error, String.t()}

  @callback spec() :: map()
  @callback execute(input()) :: result()

  defmacro __using__(_opts) do
    quote do
      @behaviour RLM.Agent.Tool

      def name, do: get_in(spec(), ["name"])

      defoverridable name: 0
    end
  end
end
