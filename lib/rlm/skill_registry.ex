defmodule RLM.SkillRegistry do
  @moduledoc """
  Stateless discovery module for Agent Skills.

  Scans configurable paths for SKILL.md files and returns skill metadata.
  Skills support progressive loading: `discover/1` reads only frontmatter
  (cheap), while `activate/2` loads full instructions (on demand).

  ## Search Paths (in priority order)

  1. Extra paths from `config :rlm, skill_paths: [...]` (highest priority)
  2. `./skills/` relative to cwd (project-local)
  3. `~/.rlm/skills/` (user-level)
  4. `priv/skills/` bundled with the app (lowest priority, defaults)

  Project skills can override bundled skills by using the same name.
  """

  require Logger

  @doc """
  Build the default list of skill search paths.

  Combines bundled, user, and project paths with any extra paths
  from config. Returns paths in priority order (highest first).
  """
  @spec default_paths(RLM.Config.t() | nil, String.t()) :: [String.t()]
  def default_paths(config \\ nil, cwd \\ File.cwd!()) do
    extra_paths =
      if config do
        config.skill_paths || []
      else
        Application.get_env(:rlm, :skill_paths, [])
      end

    bundled = Application.app_dir(:rlm, "priv/skills")

    user_dir = Path.expand("~/.rlm/skills")
    project_dir = Path.join(cwd, "skills")

    # Priority order: extra > project > user > bundled
    extra_paths ++ [project_dir, user_dir, bundled]
  end

  @doc """
  Discover all skills from the given search paths.

  Returns a map of `%{name => %RLM.Skill{loaded?: false}}`.
  Only reads frontmatter (name + description) for cheap discovery.
  First-found wins on name collisions (earlier paths have priority).
  """
  @spec discover([String.t()]) :: %{String.t() => RLM.Skill.t()}
  def discover(paths) do
    paths
    |> Enum.flat_map(&find_skill_files/1)
    |> Enum.reduce(%{}, fn path, acc ->
      case RLM.Skill.parse_metadata(path) do
        {:ok, skill} ->
          # First one wins (earlier paths have priority)
          Map.put_new(acc, skill.name, skill)

        {:error, reason} ->
          Logger.warning("Failed to parse skill at #{path}: #{inspect(reason)}")
          acc
      end
    end)
  end

  @doc """
  Get skill summaries as `[{name, description}]` tuples.

  Useful for building the system prompt skill catalog.
  """
  @spec summaries(%{String.t() => RLM.Skill.t()}) :: [{String.t(), String.t()}]
  def summaries(skills) when is_map(skills) do
    skills
    |> Enum.map(fn {name, skill} -> {name, skill.description} end)
    |> Enum.sort_by(&elem(&1, 0))
  end

  @doc """
  Activate a skill by loading its full instructions.

  Takes the discovered skills map and a skill name. Returns
  `{:ok, %Skill{loaded?: true}, updated_skills}` or `{:error, reason}`.
  """
  @spec activate(%{String.t() => RLM.Skill.t()}, String.t()) ::
          {:ok, RLM.Skill.t(), %{String.t() => RLM.Skill.t()}} | {:error, String.t()}
  def activate(skills, name) when is_map(skills) do
    case Map.fetch(skills, name) do
      {:ok, %RLM.Skill{loaded?: true} = skill} ->
        {:ok, skill, skills}

      {:ok, skill} ->
        case RLM.Skill.load_instructions(skill) do
          {:ok, loaded} ->
            {:ok, loaded, Map.put(skills, name, loaded)}

          {:error, reason} ->
            {:error, "Failed to load skill #{name}: #{inspect(reason)}"}
        end

      :error ->
        {:error, "Skill not found: #{name}"}
    end
  end

  # -- Private --

  defp find_skill_files(base_path) do
    expanded = Path.expand(base_path)

    if File.dir?(expanded) do
      case File.ls(expanded) do
        {:ok, entries} ->
          entries
          |> Enum.map(&Path.join(expanded, &1))
          |> Enum.filter(&File.dir?/1)
          |> Enum.map(&Path.join(&1, "SKILL.md"))
          |> Enum.filter(&File.regular?/1)

        {:error, _} ->
          []
      end
    else
      []
    end
  end
end
