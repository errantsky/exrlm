defmodule RLM.Skill do
  @moduledoc """
  Represents an Agent Skill loaded from a SKILL.md file.

  A skill is a multi-step workflow described in markdown that gets injected
  into the LLM's context. The LLM follows the instructions using existing
  capabilities (lm_query, parallel_query, filesystem tools).

  ## SKILL.md Format

  SKILL.md files use YAML frontmatter followed by markdown instructions,
  compatible with the [Agent Skills specification](https://agentskills.io/specification):

      ---
      name: dialectic
      description: Hegelian dialectic analysis via Electric Monks
      version: "1.0"
      ---

      # Dialectic Analysis

      Follow these steps to perform a dialectic analysis...

  ## Progressive Loading

  Skills support progressive disclosure: `parse_metadata/1` loads only
  the frontmatter (name + description) for cheap discovery, while
  `load_instructions/1` reads the full markdown body on activation.
  """

  defstruct [
    :name,
    :description,
    :instructions,
    :version,
    :license,
    :metadata,
    :path,
    loaded?: false
  ]

  @type t :: %__MODULE__{
          name: String.t(),
          description: String.t(),
          instructions: String.t() | nil,
          version: String.t() | nil,
          license: String.t() | nil,
          metadata: map() | nil,
          path: String.t(),
          loaded?: boolean()
        }

  @doc """
  Parse a SKILL.md file fully (frontmatter + instructions).

  Returns `{:ok, %Skill{loaded?: true}}` or `{:error, reason}`.
  """
  @spec parse_file(String.t()) :: {:ok, t()} | {:error, String.t()}
  def parse_file(path) do
    with {:ok, content} <- File.read(path),
         {:ok, attrs, body} <- parse_frontmatter(content),
         {:ok, skill} <- build_skill(attrs, path) do
      {:ok, %{skill | instructions: body, loaded?: true}}
    end
  end

  @doc """
  Parse only the frontmatter of a SKILL.md file for discovery.

  Returns `{:ok, %Skill{loaded?: false, instructions: nil}}` or `{:error, reason}`.
  """
  @spec parse_metadata(String.t()) :: {:ok, t()} | {:error, String.t()}
  def parse_metadata(path) do
    with {:ok, content} <- File.read(path),
         {:ok, attrs, _body} <- parse_frontmatter(content),
         {:ok, skill} <- build_skill(attrs, path) do
      {:ok, skill}
    end
  end

  @doc """
  Load the full instructions for a previously metadata-only skill.

  Re-reads the file and populates the `instructions` field.
  Returns `{:ok, %Skill{loaded?: true}}` or `{:error, reason}`.
  """
  @spec load_instructions(t()) :: {:ok, t()} | {:error, String.t()}
  def load_instructions(%__MODULE__{loaded?: true} = skill), do: {:ok, skill}

  def load_instructions(%__MODULE__{path: path} = skill) do
    with {:ok, content} <- File.read(path),
         {:ok, _attrs, body} <- parse_frontmatter(content) do
      {:ok, %{skill | instructions: body, loaded?: true}}
    end
  end

  # -- Private --

  defp parse_frontmatter(content) do
    case String.split(content, ~r/^---\s*$/m, parts: 3) do
      ["", yaml_section, body] ->
        attrs = parse_yaml_lines(yaml_section)
        {:ok, attrs, String.trim(body)}

      # Handle file starting with --- (no leading empty string from split)
      [yaml_section, body | _] when String.starts_with?(String.trim(content), "---") ->
        attrs = parse_yaml_lines(yaml_section)
        {:ok, attrs, String.trim(body)}

      _ ->
        {:error, "Missing YAML frontmatter (expected --- delimiters)"}
    end
  end

  defp parse_yaml_lines(yaml) do
    yaml
    |> String.split("\n")
    |> Enum.reject(&(String.trim(&1) == ""))
    |> parse_lines(%{}, nil)
  end

  # Parse YAML lines with support for simple nested maps (metadata:)
  defp parse_lines([], acc, _current_map_key), do: acc

  defp parse_lines([line | rest], acc, current_map_key) do
    trimmed = String.trim(line)

    cond do
      # Indented key-value under a map key
      current_map_key != nil && String.starts_with?(line, "  ") ->
        case parse_kv(trimmed) do
          {key, value} ->
            existing = Map.get(acc, current_map_key, %{})
            acc = Map.put(acc, current_map_key, Map.put(existing, key, value))
            parse_lines(rest, acc, current_map_key)

          nil ->
            parse_lines(rest, acc, current_map_key)
        end

      # Top-level key with no value (start of a map)
      match?({_, ""}, parse_kv(trimmed) || {nil, nil}) ->
        case parse_kv(trimmed) do
          {key, ""} ->
            parse_lines(rest, acc, key)

          _ ->
            parse_lines(rest, acc, nil)
        end

      # Top-level key-value
      true ->
        case parse_kv(trimmed) do
          {key, value} ->
            parse_lines(rest, Map.put(acc, key, value), nil)

          nil ->
            parse_lines(rest, acc, nil)
        end
    end
  end

  defp parse_kv(line) do
    case Regex.run(~r/^([\w][\w-]*)\s*:\s*(.*)$/, line) do
      [_, key, value] -> {key, unquote_yaml(String.trim(value))}
      _ -> nil
    end
  end

  defp unquote_yaml("\"" <> rest) do
    # Strip surrounding double quotes
    String.trim_trailing(rest, "\"")
  end

  defp unquote_yaml("'" <> rest) do
    # Strip surrounding single quotes
    String.trim_trailing(rest, "'")
  end

  defp unquote_yaml(value), do: value

  defp build_skill(attrs, path) do
    name = Map.get(attrs, "name")
    description = Map.get(attrs, "description")

    cond do
      is_nil(name) or name == "" ->
        {:error, "Missing required field: name"}

      is_nil(description) or description == "" ->
        {:error, "Missing required field: description"}

      true ->
        {:ok,
         %__MODULE__{
           name: name,
           description: description,
           version: Map.get(attrs, "version"),
           license: Map.get(attrs, "license"),
           metadata: Map.get(attrs, "metadata"),
           path: path,
           loaded?: false
         }}
    end
  end
end
