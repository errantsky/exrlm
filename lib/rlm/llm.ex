defmodule RLM.LLM do
  @moduledoc """
  Claude (Anthropic) Messages API client.
  Returns response content alongside token usage metadata.

  Uses structured output (`output_config` with JSON schema) to constrain
  LLM responses to a `{"reasoning", "code"}` JSON object, eliminating
  regex-based code extraction.
  """

  @type usage :: %{
          prompt_tokens: non_neg_integer() | nil,
          completion_tokens: non_neg_integer() | nil,
          total_tokens: non_neg_integer() | nil,
          cache_creation_input_tokens: non_neg_integer() | nil,
          cache_read_input_tokens: non_neg_integer() | nil
        }

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

  @callback chat([map()], String.t(), RLM.Config.t(), keyword()) ::
              {:ok, String.t(), usage()} | {:error, String.t()}

  @spec chat([map()], String.t(), RLM.Config.t(), keyword()) ::
          {:ok, String.t(), usage()} | {:error, String.t()}
  def chat(messages, model, config, opts \\ []) do
    url = String.trim_trailing(config.api_base_url, "/") <> "/v1/messages"

    {system_text, user_messages} = extract_system(messages)

    headers = [
      {"x-api-key", config.api_key || ""},
      {"anthropic-version", "2023-06-01"},
      {"content-type", "application/json"}
    ]

    schema = Keyword.get(opts, :schema, @response_schema)

    body = %{
      model: model,
      max_tokens: 4096,
      cache_control: %{type: "ephemeral"},
      messages: format_messages(user_messages),
      output_config: %{
        format: %{
          type: "json_schema",
          schema: schema
        }
      }
    }

    body = if system_text, do: Map.put(body, :system, system_text), else: body

    case Req.post(url,
           json: body,
           headers: headers,
           receive_timeout: config.llm_timeout
         ) do
      {:ok, %{status: 200, body: resp_body}} ->
        content = extract_content(resp_body)
        usage = extract_usage(resp_body)

        if content do
          {:ok, content, usage}
        else
          {:error, "No content in API response"}
        end

      {:ok, %{status: status, body: resp_body}} ->
        error_msg =
          case resp_body do
            %{"error" => %{"message" => msg}} -> msg
            _ -> "HTTP #{status}"
          end

        {:error, "API error: #{error_msg}"}

      {:error, reason} ->
        {:error, "API request failed: #{inspect(reason)}"}
    end
  end

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

  defp extract_system(messages) do
    case Enum.split_with(messages, fn m -> m.role == :system end) do
      {[], rest} -> {nil, rest}
      {system_msgs, rest} -> {Enum.map_join(system_msgs, "\n", & &1.content), rest}
    end
  end

  defp format_messages(messages) do
    Enum.map(messages, fn msg ->
      %{"role" => to_string(msg.role), "content" => msg.content}
    end)
  end

  defp extract_content(body) do
    body
    |> Map.get("content", [])
    |> Enum.find_value(fn
      %{"type" => "text", "text" => text} -> text
      _ -> nil
    end)
  end

  defp extract_usage(body) do
    usage = Map.get(body, "usage", %{})

    input = Map.get(usage, "input_tokens")
    output = Map.get(usage, "output_tokens")
    cache_creation = Map.get(usage, "cache_creation_input_tokens")
    cache_read = Map.get(usage, "cache_read_input_tokens")

    %{
      prompt_tokens: input,
      completion_tokens: output,
      total_tokens: if(input && output, do: input + output, else: nil),
      cache_creation_input_tokens: cache_creation,
      cache_read_input_tokens: cache_read
    }
  end
end
