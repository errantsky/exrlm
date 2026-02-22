defmodule RLM.Test.MockLLM do
  @moduledoc """
  A deterministic mock LLM for testing.

  Uses a global ETS-based response queue. Since tests run with async: false,
  this is safe from race conditions.

  Responses must be JSON strings matching the structured output schema
  (`{"reasoning": "...", "code": "..."}`). Use `mock_response/1,2` to build them.

  ## Usage

      MockLLM.program_responses([
        MockLLM.mock_response("final_answer = 42")
      ])
  """

  @table __MODULE__

  @behaviour RLM.LLM

  @doc """
  Build a JSON response matching the structured output schema.

  ## Examples

      mock_response("final_answer = 42")
      mock_response("IO.puts(:hello)", "printing hello")
  """
  def mock_response(code, reasoning \\ "") do
    Jason.encode!(%{"reasoning" => reasoning, "code" => code})
  end

  @impl true
  def chat(_messages, _model, _config) do
    response = pop_response()

    case response do
      nil ->
        # Default: set final_answer immediately
        {:ok, mock_response("final_answer = \"default mock answer\"", "default"),
         %{prompt_tokens: 10, completion_tokens: 5, total_tokens: 15}}

      {:error, reason} ->
        {:error, reason}

      text when is_binary(text) ->
        {:ok, text, %{prompt_tokens: 100, completion_tokens: 50, total_tokens: 150}}
    end
  end

  @doc "Program a sequence of responses. Call before running RLM.run."
  def program_responses(responses) when is_list(responses) do
    ensure_table()
    :ets.insert(@table, {:responses, responses})
  end

  @doc "Program responses (2-arity for backward compat, ignores pid)."
  def program_responses(_pid, responses) when is_list(responses) do
    program_responses(responses)
  end

  defp pop_response do
    ensure_table()

    case :ets.lookup(@table, :responses) do
      [{:responses, [response | rest]}] ->
        :ets.insert(@table, {:responses, rest})
        response

      _ ->
        nil
    end
  end

  defp ensure_table do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [:named_table, :public, :set])
    end

    :ok
  rescue
    ArgumentError -> :ok
  end
end
