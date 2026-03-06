defmodule RLM.LLM do
  @moduledoc """
  Behaviour for LLM backends and shared utilities for structured output parsing.

  The default implementation is `RLM.LLM.ReqLLM` which supports multiple
  providers via the `req_llm` package. The legacy hand-rolled Anthropic
  client is available as `RLM.LLM.Anthropic`.

  ## Implementations

  - `RLM.LLM.ReqLLM` — multi-provider backend (default)
  - `RLM.LLM.Anthropic` — direct Anthropic Messages API client
  - `RLM.Test.MockLLM` — deterministic test mock (ETS-based)
  - `RLM.Replay.LLM` — replay from recorded tape
  - `RLM.Replay.FallbackLLM` — replay with live fallback
  """

  @type usage :: %{
          prompt_tokens: non_neg_integer() | nil,
          completion_tokens: non_neg_integer() | nil,
          total_tokens: non_neg_integer() | nil,
          cache_creation_input_tokens: non_neg_integer() | nil,
          cache_read_input_tokens: non_neg_integer() | nil
        }

  @doc """
  Send a chat request to the LLM.

  ## Arguments

    * `messages` — list of message maps with `:role` and `:content` fields
    * `model` — model spec, optionally provider-prefixed (e.g., `"anthropic:claude-sonnet-4-6"` or bare `"claude-sonnet-4-6"`). Implementations should handle both formats.
    * `config` — `RLM.Config.t()` struct
    * `opts` — keyword list; supports `:schema` for structured output

  ## Returns

    * `{:ok, json_string, usage}` on success
    * `{:error, reason}` on failure
  """
  @callback chat([map()], String.t(), RLM.Config.t(), keyword()) ::
              {:ok, String.t(), usage()} | {:error, String.t()}

  @response_schema %{
    "type" => "object",
    "properties" => %{
      "reasoning" => %{"type" => "string"},
      "code" => %{"type" => "string"}
    },
    "required" => ["reasoning", "code"],
    "additionalProperties" => false
  }

  @doc "Returns the JSON schema used for structured LLM responses."
  @spec response_schema() :: map()
  def response_schema, do: @response_schema

  @doc """
  Parse a structured JSON response from the LLM.

  Returns `{:ok, %{reasoning: String.t(), code: String.t()}}` on success,
  or `{:error, reason}` if the JSON is invalid or missing required fields.
  """
  @spec extract_structured(String.t()) ::
          {:ok, %{reasoning: String.t(), code: String.t()}} | {:error, String.t()}
  def extract_structured(response_text) do
    case Jason.decode(response_text) do
      {:ok, %{"reasoning" => reasoning, "code" => code}}
      when is_binary(reasoning) and is_binary(code) ->
        {:ok, %{reasoning: reasoning, code: code}}

      {:ok, _} ->
        {:error, "Missing required fields in structured response"}

      {:error, err} ->
        {:error, "JSON parse failed: #{inspect(err)}"}
    end
  end
end
