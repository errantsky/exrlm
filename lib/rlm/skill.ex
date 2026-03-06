defmodule RLM.Skill do
  @moduledoc """
  Parsed representation of an Agent Skills `SKILL.md` file.

  Handles YAML frontmatter parsing, validation, and progressive disclosure:

  - **Tier 1** (catalog): `name` + `description` (~100 tokens per skill)
  - **Tier 2** (activated): full `SKILL.md` body injected into conversation
  - **Tier 3** (on-demand): `scripts/`, `references/`, `assets/` via `read_file`

  ## SKILL.md Format

  A SKILL.md file has YAML frontmatter between `---` delimiters followed by
  markdown instructions:

      ---
      name: my-skill
      description: What this skill does and when to use it.
      ---
      # Instructions
      Step-by-step guidance for the agent.

  See the [Agent Skills specification](https://agentskills.io/specification)
  for the full format definition.
  """

  require Logger

  @enforce_keys [:name, :description, :path, :dir, :body]
  defstruct [
    :name,
    :description,
    :path,
    :dir,
    :body,
    :license,
    :compatibility,
    :metadata,
    :allowed_tools
  ]

  @type t :: %__MODULE__{
          name: String.t(),
          description: String.t(),
          path: String.t(),
          dir: String.t(),
          body: String.t(),
          license: String.t() | nil,
          compatibility: String.t() | nil,
          metadata: %{String.t() => String.t()} | nil,
          allowed_tools: [String.t()] | nil
        }

  @doc """
  Parse a SKILL.md file at the given path.

  Returns `{:ok, %Skill{}}` on success or `{:error, reason}` on failure.
  Validation is lenient: warns on non-critical issues (name/directory mismatch,
  long descriptions) but only fails on missing required fields or unparseable YAML.
  """
  @spec parse(String.t()) :: {:ok, t()} | {:error, String.t()}
  def parse(path) do
    with {:ok, content} <- read_file(path),
         {:ok, yaml_str, body} <- split_frontmatter(content),
         {:ok, frontmatter} <- parse_yaml(yaml_str),
         {:ok, skill} <- build_skill(frontmatter, body, path) do
      maybe_warn_name_mismatch(skill)
      {:ok, skill}
    end
  end

  @doc """
  Validate a skill name against the Agent Skills spec.

  Rules:
  - 1-64 characters
  - Lowercase letters, numbers, and hyphens only
  - Must not start or end with a hyphen
  - Must not contain consecutive hyphens
  """
  @spec validate_name(String.t()) :: :ok | {:error, String.t()}
  def validate_name(""), do: {:error, "name must not be empty"}

  def validate_name(name) when is_binary(name) do
    cond do
      String.length(name) > 64 ->
        {:error, "name must be 64 characters or fewer"}

      name != String.downcase(name) ->
        {:error, "name must contain only lowercase characters"}

      not Regex.match?(~r/^[a-z0-9][a-z0-9-]*[a-z0-9]$|^[a-z0-9]$/, name) ->
        {:error,
         "name must not start or end with a hyphen and must contain only lowercase letters, numbers, and hyphens"}

      String.contains?(name, "--") ->
        {:error, "name must not contain consecutive hyphens"}

      true ->
        :ok
    end
  end

  @doc """
  Return the tier-1 catalog entry for a skill (name, description, path only).
  """
  @spec catalog_entry(t()) :: %{name: String.t(), description: String.t(), path: String.t()}
  def catalog_entry(%__MODULE__{} = skill) do
    %{name: skill.name, description: skill.description, path: skill.path}
  end

  # -- Private --

  defp read_file(path) do
    case File.read(path) do
      {:ok, ""} -> {:error, "SKILL.md is empty"}
      {:ok, content} -> {:ok, content}
      {:error, reason} -> {:error, "Could not read #{path}: #{inspect(reason)}"}
    end
  end

  defp split_frontmatter(content) do
    case String.split(content, ~r/^---\s*$/m, parts: 3) do
      ["", yaml_str, body] ->
        {:ok, String.trim(yaml_str), String.trim(body)}

      _ ->
        {:error, "SKILL.md must begin with YAML frontmatter delimited by ---"}
    end
  end

  defp parse_yaml(yaml_str) do
    case YamlElixir.read_from_string(yaml_str) do
      {:ok, map} when is_map(map) ->
        {:ok, map}

      {:ok, _other} ->
        {:error, "YAML frontmatter must be a mapping (key-value pairs)"}

      {:error, reason} ->
        {:error, "Failed to parse YAML frontmatter: #{inspect(reason)}"}
    end
  end

  defp build_skill(frontmatter, body, path) do
    name = frontmatter["name"]
    description = frontmatter["description"]

    cond do
      is_nil(name) or name == "" ->
        {:error, "SKILL.md frontmatter must include a 'name' field"}

      is_nil(description) or description == "" ->
        {:error, "SKILL.md frontmatter must include a 'description' field"}

      true ->
        name = to_string(name)
        description = to_string(description)

        allowed_tools =
          case frontmatter["allowed-tools"] do
            nil -> nil
            tools when is_binary(tools) -> String.split(tools)
            tools when is_list(tools) -> tools
          end

        skill = %__MODULE__{
          name: name,
          description: description,
          path: path,
          dir: Path.dirname(path),
          body: body,
          license: frontmatter["license"],
          compatibility: frontmatter["compatibility"],
          metadata: frontmatter["metadata"],
          allowed_tools: allowed_tools
        }

        {:ok, skill}
    end
  end

  defp maybe_warn_name_mismatch(%__MODULE__{name: name, path: path}) do
    dir_name = path |> Path.dirname() |> Path.basename()

    if name != dir_name do
      Logger.warning("Skill '#{name}' directory name '#{dir_name}' does not match the name field")
    end
  end
end
