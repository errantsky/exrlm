defmodule RLM.LLM.Anthropic do
  @moduledoc """
  Hand-rolled Anthropic Messages API client.

  Preserved for users who prefer a dependency-free Anthropic-only client
  or need to customize Anthropic API request bodies directly (e.g., custom
  headers, non-standard API versions). The default backend is `RLM.LLM.ReqLLM`.

  Select this at call time:

      RLM.run(context, query, llm_module: RLM.LLM.Anthropic)
  """

  @behaviour RLM.LLM

  @impl true
  def chat(messages, model, config, opts \\ []) do
    url = String.trim_trailing(config.api_base_url, "/") <> "/v1/messages"
    model = strip_provider_prefix(model)

    {system_text, user_messages} = extract_system(messages)

    headers = [
      {"x-api-key", config.api_key || ""},
      {"anthropic-version", "2023-06-01"},
      {"content-type", "application/json"}
    ]

    schema = Keyword.get(opts, :schema, RLM.LLM.response_schema())

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

  # Strip "anthropic:" prefix if present (models map stores provider-prefixed specs)
  defp strip_provider_prefix("anthropic:" <> bare), do: bare
  defp strip_provider_prefix(model), do: model

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
