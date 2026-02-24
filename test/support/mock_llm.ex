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

  @doc """
  Build a raw JSON string for direct query (schema mode) mock responses.
  Takes a map and encodes it as JSON.

  ## Examples

      mock_direct_response(%{"names" => ["Alice", "Bob"]})
  """
  def mock_direct_response(data) when is_map(data), do: Jason.encode!(data)

  @doc """
  Build a direct query mock response, validating `data` against `schema` first.
  Raises `ArgumentError` if the data doesn't conform, catching test bugs early.

  ## Examples

      schema = %{"type" => "object", "properties" => %{"name" => %{"type" => "string"}},
                  "required" => ["name"], "additionalProperties" => false}
      mock_direct_response(%{"name" => "Alice"}, schema)   # => "{\"name\":\"Alice\"}"
      mock_direct_response(%{"age" => 30}, schema)          # => raises ArgumentError
  """
  def mock_direct_response(data, schema) when is_map(data) and is_map(schema) do
    case validate_schema(data, schema) do
      :ok ->
        Jason.encode!(data)

      {:error, errors} ->
        raise ArgumentError,
              "mock_direct_response: data does not conform to schema\n" <>
                "  data:   #{inspect(data)}\n" <>
                "  errors: #{Enum.join(errors, "; ")}"
    end
  end

  # -- Lightweight JSON Schema validation (covers the subset used in RLM) --

  defp validate_schema(data, schema) do
    errors = check(data, schema, [])
    if errors == [], do: :ok, else: {:error, Enum.reverse(errors)}
  end

  defp check(data, schema, errors) do
    errors
    |> check_type(data, schema)
    |> check_required(data, schema)
    |> check_additional_properties(data, schema)
    |> check_properties(data, schema)
    |> check_items(data, schema)
  end

  defp check_type(errors, data, %{"type" => type}) do
    if type_matches?(data, type),
      do: errors,
      else: ["expected type #{type}, got #{inspect(data)}" | errors]
  end

  defp check_type(errors, _data, _schema), do: errors

  defp type_matches?(v, "object") when is_map(v), do: true
  defp type_matches?(v, "array") when is_list(v), do: true
  defp type_matches?(v, "string") when is_binary(v), do: true
  defp type_matches?(v, "integer") when is_integer(v), do: true
  defp type_matches?(v, "number") when is_number(v), do: true
  defp type_matches?(v, "boolean") when is_boolean(v), do: true
  defp type_matches?(nil, "null"), do: true
  defp type_matches?(_v, _type), do: false

  defp check_required(errors, data, %{"required" => keys}) when is_map(data) do
    Enum.reduce(keys, errors, fn key, acc ->
      if Map.has_key?(data, key),
        do: acc,
        else: ["missing required key #{inspect(key)}" | acc]
    end)
  end

  defp check_required(errors, _data, _schema), do: errors

  defp check_additional_properties(errors, data, %{
         "additionalProperties" => false,
         "properties" => props
       })
       when is_map(data) do
    allowed = Map.keys(props) |> MapSet.new()
    extra = Map.keys(data) |> MapSet.new() |> MapSet.difference(allowed) |> MapSet.to_list()

    if extra == [],
      do: errors,
      else: ["unexpected keys: #{inspect(extra)}" | errors]
  end

  defp check_additional_properties(errors, _data, _schema), do: errors

  defp check_properties(errors, data, %{"properties" => props}) when is_map(data) do
    Enum.reduce(props, errors, fn {key, sub_schema}, acc ->
      case Map.fetch(data, key) do
        {:ok, value} -> check(value, sub_schema, acc)
        :error -> acc
      end
    end)
  end

  defp check_properties(errors, _data, _schema), do: errors

  defp check_items(errors, data, %{"items" => item_schema}) when is_list(data) do
    Enum.reduce(data, errors, fn item, acc -> check(item, item_schema, acc) end)
  end

  defp check_items(errors, _data, _schema), do: errors

  @impl true
  def chat(messages, model, config, opts \\ [])

  def chat(_messages, _model, _config, _opts) do
    response = pop_response()

    case response do
      nil ->
        # Default: set final_answer immediately
        {:ok, mock_response("final_answer = \"default mock answer\"", "default"),
         %{
           prompt_tokens: 10,
           completion_tokens: 5,
           total_tokens: 15,
           cache_creation_input_tokens: nil,
           cache_read_input_tokens: nil
         }}

      {:error, reason} ->
        {:error, reason}

      text when is_binary(text) ->
        {:ok, text,
         %{
           prompt_tokens: 100,
           completion_tokens: 50,
           total_tokens: 150,
           cache_creation_input_tokens: nil,
           cache_read_input_tokens: nil
         }}
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
