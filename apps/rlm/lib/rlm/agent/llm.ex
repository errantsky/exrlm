defmodule RLM.Agent.LLM do
  @moduledoc """
  Anthropic Messages API client for the coding agent.

  Supports:
  - Native `tool_use` content blocks (required for the agent loop)
  - SSE streaming for real-time token delivery to LiveView
  - A clean accumulator-based streaming implementation that handles
    chunked HTTP delivery and partial SSE event boundaries

  ## Return values

      {:ok, {:text, text}, usage}
      {:ok, {:tool_calls, [call], text_or_nil}, usage}
      {:error, reason}

  where `usage` is `%{input_tokens: n, output_tokens: n}`.

  ## Streaming

  Pass `stream: true` and `on_chunk: fn text -> :ok end` in opts to receive
  incremental text deltas as the model generates them. Tool-use input is
  accumulated silently and returned in the final `{:tool_calls, ...}` tuple.
  """

  alias RLM.Agent.Message

  @anthropic_version "2023-06-01"
  @default_max_tokens 8192

  @type tool_call :: %{id: String.t(), name: String.t(), input: map()}
  @type response ::
          {:text, String.t()}
          | {:tool_calls, [tool_call()], String.t() | nil}

  @type usage :: %{input_tokens: non_neg_integer(), output_tokens: non_neg_integer()}

  @doc """
  Call the Anthropic Messages API.

  Options:
    - `:tools`       — list of tool definition maps (see `RLM.Agent.Tool`)
    - `:tool_choice` — `nil` | `"auto"` | `"any"` | `%{"type" => "tool", "name" => "..."}`
    - `:system`      — system prompt string
    - `:max_tokens`  — defaults to 8192
    - `:stream`      — stream SSE chunks (default: false)
    - `:on_chunk`    — `fn text_delta -> :ok end` callback for streaming text
  """
  @spec call([Message.t()], String.t(), RLM.Config.t(), keyword()) ::
          {:ok, response(), usage()} | {:error, String.t()}
  def call(messages, model, config, opts \\ []) do
    url = String.trim_trailing(config.api_base_url, "/") <> "/v1/messages"
    tools = Keyword.get(opts, :tools, [])
    tool_choice = Keyword.get(opts, :tool_choice, nil)
    system = Keyword.get(opts, :system, nil)
    max_tokens = Keyword.get(opts, :max_tokens, @default_max_tokens)
    stream = Keyword.get(opts, :stream, false)
    on_chunk = Keyword.get(opts, :on_chunk, nil)

    headers = [
      {"x-api-key", config.api_key || ""},
      {"anthropic-version", @anthropic_version},
      {"content-type", "application/json"}
    ]

    body =
      %{
        model: model,
        max_tokens: max_tokens,
        messages: Enum.map(messages, &Message.to_api_map/1),
        stream: stream
      }
      |> maybe_put(:system, system)
      |> maybe_put(:tools, if(tools != [], do: tools, else: nil))
      |> maybe_put(:tool_choice, tool_choice)

    if stream do
      call_streaming(url, headers, body, config, on_chunk)
    else
      call_sync(url, headers, body, config)
    end
  end

  # ---------------------------------------------------------------------------
  # Synchronous (non-streaming)
  # ---------------------------------------------------------------------------

  defp call_sync(url, headers, body, config) do
    case Req.post(url, json: body, headers: headers, receive_timeout: config.llm_timeout) do
      {:ok, %{status: 200, body: resp_body}} ->
        parse_sync_response(resp_body)

      {:ok, %{status: status, body: resp_body}} ->
        {:error, "API error: #{extract_error_message(resp_body, status)}"}

      {:error, reason} ->
        {:error, "API request failed: #{inspect(reason)}"}
    end
  end

  defp parse_sync_response(body) do
    blocks = Map.get(body, "content", [])
    stop_reason = Map.get(body, "stop_reason")
    usage = extract_usage(body)
    %{text: text, tool_calls: tool_calls} = Message.parse_response_content(blocks)

    result =
      case {stop_reason, tool_calls} do
        {"tool_use", [_ | _]} -> {:tool_calls, tool_calls, text}
        _ -> {:text, text || ""}
      end

    {:ok, result, usage}
  end

  # ---------------------------------------------------------------------------
  # SSE streaming
  # ---------------------------------------------------------------------------

  # The Anthropic SSE stream emits newline-delimited events. Each event block
  # is separated by "\n\n". HTTP chunks may split events mid-line, so we keep
  # a running buffer of incomplete data.

  defp initial_streaming_acc do
    %{
      buffer: "",
      text_chunks: [],
      # index => {id, name, [json_chunk]}
      tool_blocks: %{},
      stop_reason: nil,
      usage: nil
    }
  end

  defp call_streaming(url, headers, body, config, on_chunk) do
    result =
      Req.post(url,
        json: body,
        headers: headers,
        receive_timeout: config.llm_timeout,
        into: fn {:data, chunk}, acc ->
          # Req may pass nil as the initial accumulator — normalise on first call
          acc = if is_map(acc), do: acc, else: initial_streaming_acc()
          {events, new_buffer} = flush_sse_buffer(acc.buffer <> chunk)

          new_acc =
            Enum.reduce(events, %{acc | buffer: new_buffer}, &process_sse_event(&1, &2, on_chunk))

          {:cont, new_acc}
        end,
        raw: true
      )

    case result do
      {:ok, %{status: 200, body: final_acc}} ->
        build_streaming_response(final_acc)

      {:ok, %{status: _status, body: %{"error" => %{"message" => msg}}}} ->
        {:error, "API error: #{msg}"}

      {:ok, %{status: status}} ->
        {:error, "API error: HTTP #{status}"}

      {:error, reason} ->
        {:error, "API request failed: #{inspect(reason)}"}
    end
  end

  # Split buffered bytes into complete SSE event blocks and a remainder.
  defp flush_sse_buffer(buffer) do
    parts = String.split(buffer, "\n\n")

    case parts do
      [_incomplete] ->
        {[], buffer}

      _ ->
        {complete_parts, [remainder]} = Enum.split(parts, -1)
        events = Enum.flat_map(complete_parts, &parse_sse_block/1)
        {events, remainder}
    end
  end

  defp parse_sse_block(block) do
    block
    |> String.split("\n")
    |> Enum.flat_map(fn
      "data: [DONE]" ->
        []

      "data: " <> json ->
        case Jason.decode(json) do
          {:ok, event} -> [event]
          _ -> []
        end

      _ ->
        []
    end)
  end

  defp process_sse_event(%{"type" => "content_block_start"} = event, acc, _on_chunk) do
    block = Map.get(event, "content_block", %{})
    index = Map.get(event, "index")

    case block do
      %{"type" => "tool_use", "id" => id, "name" => name} ->
        %{acc | tool_blocks: Map.put(acc.tool_blocks, index, {id, name, []})}

      _ ->
        acc
    end
  end

  defp process_sse_event(%{"type" => "content_block_delta"} = event, acc, on_chunk) do
    delta = Map.get(event, "delta", %{})
    index = Map.get(event, "index")

    case delta do
      %{"type" => "text_delta", "text" => text} ->
        if on_chunk, do: on_chunk.(text)
        %{acc | text_chunks: [text | acc.text_chunks]}

      %{"type" => "input_json_delta", "partial_json" => json} ->
        updated_blocks =
          Map.update(acc.tool_blocks, index, {"", "", [json]}, fn {id, name, chunks} ->
            {id, name, [json | chunks]}
          end)

        %{acc | tool_blocks: updated_blocks}

      _ ->
        acc
    end
  end

  defp process_sse_event(%{"type" => "message_delta"} = event, acc, _on_chunk) do
    acc
    |> maybe_update_stop_reason(event)
    |> maybe_update_usage(event)
  end

  defp process_sse_event(%{"type" => "message_start"} = event, acc, _on_chunk) do
    case get_in(event, ["message", "usage"]) do
      nil -> acc
      usage -> %{acc | usage: parse_usage_map(usage)}
    end
  end

  defp process_sse_event(_event, acc, _on_chunk), do: acc

  defp maybe_update_stop_reason(acc, %{"delta" => %{"stop_reason" => reason}}) do
    %{acc | stop_reason: reason}
  end

  defp maybe_update_stop_reason(acc, _), do: acc

  defp maybe_update_usage(acc, %{"usage" => usage}) do
    %{acc | usage: parse_usage_map(usage)}
  end

  defp maybe_update_usage(acc, _), do: acc

  defp parse_usage_map(usage_map) do
    %{
      input_tokens: Map.get(usage_map, "input_tokens", 0),
      output_tokens: Map.get(usage_map, "output_tokens", 0)
    }
  end

  defp build_streaming_response(acc) do
    text = acc.text_chunks |> Enum.reverse() |> Enum.join()
    usage = acc.usage || %{input_tokens: 0, output_tokens: 0}

    tool_calls =
      acc.tool_blocks
      |> Enum.sort_by(fn {index, _} -> index end)
      |> Enum.flat_map(fn
        {_, {id, name, json_chunks}} ->
          json = json_chunks |> Enum.reverse() |> Enum.join()

          case Jason.decode(json) do
            {:ok, input} -> [%{id: id, name: name, input: input}]
            _ -> []
          end

        _ ->
          []
      end)

    result =
      case {acc.stop_reason, tool_calls} do
        {"tool_use", [_ | _]} ->
          {:tool_calls, tool_calls, if(text == "", do: nil, else: text)}

        _ ->
          {:text, text}
      end

    {:ok, result, usage}
  end

  # ---------------------------------------------------------------------------
  # Shared helpers
  # ---------------------------------------------------------------------------

  defp extract_usage(body) do
    usage = Map.get(body, "usage", %{})

    %{
      input_tokens: Map.get(usage, "input_tokens", 0),
      output_tokens: Map.get(usage, "output_tokens", 0)
    }
  end

  defp extract_error_message(%{"error" => %{"message" => msg}}, _status), do: msg
  defp extract_error_message(_, status), do: "HTTP #{status}"

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
