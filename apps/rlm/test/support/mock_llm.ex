defmodule RLM.Test.MockLLM do
  @moduledoc """
  A deterministic mock LLM for testing.

  Uses a global ETS-based response queue. Since tests run with async: false,
  this is safe from race conditions.

  ## Usage

      MockLLM.program_responses([
        "```elixir\\nfinal_answer = 42\\n```"
      ])
  """

  @table __MODULE__

  @behaviour RLM.LLM

  @impl true
  def chat(_messages, _model, _config) do
    response = pop_response()

    case response do
      nil ->
        # Default: set final_answer immediately
        {:ok, "```elixir\nfinal_answer = \"default mock answer\"\n```",
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
