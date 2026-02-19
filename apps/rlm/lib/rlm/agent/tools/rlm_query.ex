defmodule RLM.Agent.Tools.RlmQuery do
  @moduledoc """
  The RLM bridge tool — lets the coding agent delegate data-processing
  sub-tasks to the RLM engine (recursive code-execution loop).

  This is the key integration point between the two execution models:
  the agent uses tool_use to make a high-level decision, then the RLM
  engine handles the heavy lifting with its sandboxed Elixir REPL.
  """

  use RLM.Agent.Tool

  @impl true
  def spec do
    %{
      "name" => "rlm_query",
      "description" => """
      Delegate a data-processing task to the RLM engine, which will write
      and execute Elixir code iteratively until it finds an answer.
      Use this for: analyzing large files, transforming data, computing metrics,
      or any task that benefits from an iterative code-writing approach.
      """,
      "input_schema" => %{
        "type" => "object",
        "properties" => %{
          "context" => %{
            "type" => "string",
            "description" =>
              "The data or context to process (can be file contents, raw data, etc.)"
          },
          "query" => %{
            "type" => "string",
            "description" => "The question or task to perform on the context"
          },
          "model_size" => %{
            "type" => "string",
            "enum" => ["large", "small"],
            "description" =>
              "Model to use: 'large' for complex tasks, 'small' for simple ones (default: small)"
          }
        },
        "required" => ["context", "query"]
      }
    }
  end

  @impl true
  def execute(%{"context" => context, "query" => query} = input) do
    model_size = Map.get(input, "model_size", "small")
    llm_module = Application.get_env(:rlm, :llm_module, RLM.LLM)

    opts = [llm_module: llm_module]

    opts =
      if model_size == "large",
        do: opts,
        else: Keyword.put(opts, :model_large, RLM.Config.load().model_small)

    case RLM.run(context, query, opts) do
      {:ok, result, _run_id} ->
        {:ok, inspect(result)}

      {:error, reason} ->
        {:error, "RLM query failed: #{reason}"}
    end
  end
end
