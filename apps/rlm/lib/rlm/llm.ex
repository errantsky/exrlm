defmodule RLM.LLM do
  @moduledoc """
  Claude (Anthropic) Messages API client.
  Returns response content alongside token usage metadata.
  """

  @type usage :: %{
          prompt_tokens: non_neg_integer() | nil,
          completion_tokens: non_neg_integer() | nil,
          total_tokens: non_neg_integer() | nil
        }

  @callback chat([map()], String.t(), RLM.Config.t()) ::
              {:ok, String.t(), usage()} | {:error, String.t()}

  @spec chat([map()], String.t(), RLM.Config.t()) ::
          {:ok, String.t(), usage()} | {:error, String.t()}
  def chat(messages, model, config) do
    url = String.trim_trailing(config.api_base_url, "/") <> "/v1/messages"

    {system_text, user_messages} = extract_system(messages)

    headers = [
      {"x-api-key", config.api_key || ""},
      {"anthropic-version", "2023-06-01"},
      {"content-type", "application/json"}
    ]

    body = %{
      model: model,
      max_tokens: 4096,
      messages: format_messages(user_messages)
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

  @spec extract_code(String.t()) :: {:ok, String.t()} | {:error, :no_code_block}
  def extract_code(response) do
    regex = ~r/```(?:elixir|Elixir)\s*\n(.*?)```/s

    case Regex.scan(regex, response) do
      [] -> {:error, :no_code_block}
      matches -> {:ok, matches |> List.last() |> Enum.at(1) |> String.trim()}
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

    %{
      prompt_tokens: input,
      completion_tokens: output,
      total_tokens: if(input && output, do: input + output, else: nil)
    }
  end
end
