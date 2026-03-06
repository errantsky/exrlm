defmodule RLM.LLM.Ollama do
  @moduledoc """
  Ollama LLM backend — talks directly to a local Ollama server via its
  OpenAI-compatible `/v1/chat/completions` endpoint using `Req`.

  No external LLM library needed. Works with any model Ollama serves.

  ## Usage

      RLM.run(context, query,
        llm_module: RLM.LLM.Ollama,
        models: %{large: "qwen3.5:9b", small: "qwen3.5:9b"}
      )

  ## Configuration

  The Ollama base URL defaults to `http://localhost:11434`. Override via:

  - `OLLAMA_HOST` environment variable
  - `config :rlm, :ollama_base_url, "http://..."` in your config
  """

  @behaviour RLM.LLM

  @default_base_url "http://localhost:11434"

  @impl true
  def chat(messages, model, config, opts \\ []) do
    url = base_url() <> "/v1/chat/completions"
    schema = Keyword.get(opts, :schema, RLM.LLM.response_schema())

    {system_text, user_messages} = extract_system(messages)

    api_messages =
      if system_text do
        [%{"role" => "system", "content" => system_text} | format_messages(user_messages)]
      else
        format_messages(user_messages)
      end

    body = %{
      model: model,
      messages: api_messages,
      max_tokens: 4096,
      response_format: %{
        type: "json_schema",
        json_schema: %{
          name: "response",
          strict: true,
          schema: schema
        }
      }
    }

    case Req.post(url, json: body, receive_timeout: config.llm_timeout) do
      {:ok, %{status: 200, body: resp_body}} ->
        case extract_content(resp_body) do
          {:ok, content} ->
            usage = extract_usage(resp_body)
            {:ok, content, usage}

          :error ->
            {:error, "No content in Ollama response"}
        end

      {:ok, %{status: status, body: resp_body}} ->
        msg =
          case resp_body do
            %{"error" => %{"message" => m}} -> m
            %{"error" => m} when is_binary(m) -> m
            _ -> "HTTP #{status}"
          end

        {:error, "Ollama API error: #{msg}"}

      {:error, reason} ->
        {:error, "Ollama request failed: #{inspect(reason)}"}
    end
  end

  defp base_url do
    System.get_env("OLLAMA_HOST") ||
      Application.get_env(:rlm, :ollama_base_url, @default_base_url)
  end

  defp extract_system(messages) do
    case Enum.split_with(messages, fn m -> m.role == :system end) do
      {[], rest} -> {nil, rest}
      {sys, rest} -> {Enum.map_join(sys, "\n", & &1.content), rest}
    end
  end

  defp format_messages(messages) do
    Enum.map(messages, fn msg ->
      %{"role" => to_string(msg.role), "content" => msg.content}
    end)
  end

  defp extract_content(%{"choices" => [%{"message" => %{"content" => c}} | _]})
       when is_binary(c) and c != "",
       do: {:ok, c}

  defp extract_content(_), do: :error

  defp extract_usage(%{"usage" => u}) when is_map(u) do
    %{
      prompt_tokens: Map.get(u, "prompt_tokens"),
      completion_tokens: Map.get(u, "completion_tokens"),
      total_tokens: Map.get(u, "total_tokens"),
      cache_creation_input_tokens: nil,
      cache_read_input_tokens: nil
    }
  end

  defp extract_usage(_) do
    %{
      prompt_tokens: nil,
      completion_tokens: nil,
      total_tokens: nil,
      cache_creation_input_tokens: nil,
      cache_read_input_tokens: nil
    }
  end
end
