defmodule RLM.Agent.Message do
  @moduledoc """
  Helpers for constructing Anthropic Messages API message maps.

  The Anthropic tool_use protocol extends the normal text-only format with
  structured content blocks. This module provides builders for both the
  standard text messages and the richer tool_use / tool_result format.

  ## Content block types

  - `text`        — plain text from assistant or user
  - `tool_use`    — a tool call emitted by the assistant
  - `tool_result` — the result returned to the assistant after executing a tool
  """

  @type role :: :user | :assistant | :system
  @type content :: String.t() | [map()]

  @type t :: %{role: role(), content: content()}

  # -- Constructors --

  @spec system(String.t()) :: t()
  def system(text), do: %{role: :system, content: text}

  @spec user(String.t()) :: t()
  def user(text), do: %{role: :user, content: text}

  @spec assistant(String.t()) :: t()
  def assistant(text), do: %{role: :assistant, content: text}

  @doc """
  Build an assistant message from a list of content blocks returned by the API.
  The blocks may include text and/or tool_use entries.
  """
  @spec assistant_from_blocks([map()]) :: t()
  def assistant_from_blocks(blocks), do: %{role: :assistant, content: blocks}

  @doc """
  Build a user message carrying one or more tool results.
  `results` is a list of `%{tool_use_id: id, content: output, is_error: bool}`.
  """
  @spec tool_results([map()]) :: t()
  def tool_results(results) do
    blocks =
      Enum.map(results, fn %{tool_use_id: id, content: content} = r ->
        %{
          "type" => "tool_result",
          "tool_use_id" => id,
          "content" => stringify(content),
          "is_error" => Map.get(r, :is_error, false)
        }
      end)

    %{role: :user, content: blocks}
  end

  @doc """
  Build a single tool result user message for one tool call.
  """
  @spec tool_result(String.t(), any(), boolean()) :: t()
  def tool_result(tool_use_id, content, is_error \\ false) do
    tool_results([%{tool_use_id: tool_use_id, content: content, is_error: is_error}])
  end

  # -- Serialisation --

  @doc """
  Convert a message to the wire format expected by the Anthropic API.
  """
  @spec to_api_map(t()) :: map()
  def to_api_map(%{role: role, content: content}) when is_binary(content) do
    %{"role" => to_string(role), "content" => content}
  end

  def to_api_map(%{role: role, content: blocks}) when is_list(blocks) do
    %{"role" => to_string(role), "content" => blocks}
  end

  # -- Parsing --

  @doc """
  Parse the response content blocks from an API response into a structured
  `%{text: String.t() | nil, tool_calls: [tool_call()]}` map.
  """
  @spec parse_response_content([map()]) :: %{
          text: String.t() | nil,
          tool_calls: [%{id: String.t(), name: String.t(), input: map()}]
        }
  def parse_response_content(blocks) do
    text =
      Enum.find_value(blocks, fn
        %{"type" => "text", "text" => t} -> t
        _ -> nil
      end)

    tool_calls =
      Enum.flat_map(blocks, fn
        %{"type" => "tool_use", "id" => id, "name" => name, "input" => input} ->
          [%{id: id, name: name, input: input}]

        _ ->
          []
      end)

    %{text: text, tool_calls: tool_calls}
  end

  # -- Private --

  defp stringify(value) when is_binary(value), do: value
  defp stringify(value), do: inspect(value)
end
