defmodule RLM.LLM.ReqLLM do
  @moduledoc """
  Multi-provider LLM backend using the `req_llm` package.

  Supports any provider that `req_llm` supports: Anthropic, OpenAI,
  Ollama (local models), Google Gemini, Groq, and more. Model specs follow
  the `"provider:model-name"` convention.

  For backward compatibility, bare model names without a provider prefix
  are treated as Anthropic models (e.g., `"claude-sonnet-4-6"` becomes
  `"anthropic:claude-sonnet-4-6"`).

  ## Provider-Specific Features

  - **Anthropic**: Prompt caching enabled automatically via `anthropic_prompt_cache: true`
  - **Ollama**: No API key needed; uses `http://localhost:11434` by default
  - **OpenAI**: Reads `OPENAI_API_KEY` from env
  """

  @behaviour RLM.LLM

  @impl true
  def chat(messages, model, config, opts \\ []) do
    model_spec = normalize_model_spec(model)
    schema = Keyword.get(opts, :schema, RLM.LLM.response_schema())
    context = build_context(messages)
    req_opts = build_opts(model_spec, config)

    case ReqLLM.generate_object(model_spec, context, schema, req_opts) do
      {:ok, response} ->
        case encode_object(response) do
          {:error, :no_content} ->
            {:error, "LLM response contained no usable content (no structured object or text)"}

          content when is_binary(content) ->
            usage = extract_usage(response)
            {:ok, content, usage}
        end

      {:error, reason} ->
        {:error, format_error(reason)}
    end
  end

  # If model string already contains ":", it's in provider:model format.
  # Otherwise, assume Anthropic for backward compatibility.
  defp normalize_model_spec(model) when is_binary(model) do
    if String.contains?(model, ":") do
      model
    else
      "anthropic:#{model}"
    end
  end

  defp build_context(messages) do
    {system_msgs, user_msgs} =
      Enum.split_with(messages, fn m -> m.role == :system end)

    system_text =
      case system_msgs do
        [] -> nil
        msgs -> Enum.map_join(msgs, "\n", & &1.content)
      end

    req_messages =
      Enum.map(user_msgs, fn msg ->
        case msg.role do
          :user -> ReqLLM.Context.user(msg.content)
          :assistant -> ReqLLM.Context.assistant(msg.content)
          other -> raise ArgumentError, "unsupported message role #{inspect(other)}"
        end
      end)

    all_messages =
      if system_text do
        [ReqLLM.Context.system(system_text) | req_messages]
      else
        req_messages
      end

    ReqLLM.Context.new(all_messages)
  end

  defp build_opts(model_spec, config) do
    base_opts = [
      max_tokens: 4096,
      receive_timeout: config.llm_timeout
    ]

    base_opts
    |> maybe_add_api_key(config)
    |> maybe_add_anthropic_opts(model_spec)
  end

  defp maybe_add_api_key(opts, config) do
    if config.api_key do
      Keyword.put(opts, :api_key, config.api_key)
    else
      opts
    end
  end

  defp maybe_add_anthropic_opts(opts, model_spec) do
    if anthropic_model?(model_spec) do
      Keyword.put(opts, :anthropic_prompt_cache, true)
    else
      opts
    end
  end

  defp anthropic_model?(spec), do: String.starts_with?(spec, "anthropic:")

  # Re-serialize the parsed object back to a JSON string to preserve
  # the existing chat/4 contract (Worker expects a JSON string).
  defp encode_object(response) do
    case ReqLLM.Response.object(response) do
      obj when is_map(obj) ->
        Jason.encode!(obj)

      _ ->
        case ReqLLM.Response.text(response) do
          text when is_binary(text) and text != "" -> text
          _ -> {:error, :no_content}
        end
    end
  end

  defp extract_usage(response) do
    raw = ReqLLM.Response.usage(response) || %{}

    usage = %{
      prompt_tokens: Map.get(raw, :input_tokens),
      completion_tokens: Map.get(raw, :output_tokens),
      total_tokens: Map.get(raw, :total_tokens),
      # Anthropic provider includes :cache_creation_input_tokens;
      # other providers use the normalized :cache_creation_tokens key
      cache_creation_input_tokens:
        Map.get(raw, :cache_creation_input_tokens) || Map.get(raw, :cache_creation_tokens),
      cache_read_input_tokens:
        Map.get(raw, :cache_read_input_tokens) || Map.get(raw, :cached_tokens)
    }

    if raw != %{} and is_nil(usage.prompt_tokens) and is_nil(usage.completion_tokens) do
      require Logger

      Logger.warning(
        "Could not extract token usage from LLM response. Raw usage keys: #{inspect(Map.keys(raw))}"
      )
    end

    usage
  end

  defp format_error(%{__exception__: true} = error), do: Exception.message(error)
  defp format_error(reason), do: "LLM request failed: #{inspect(reason)}"
end
