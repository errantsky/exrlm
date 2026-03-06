defmodule RLM.SkillRegistry do
  @moduledoc """
  GenServer that discovers, caches, and serves Agent Skills.

  Scans configured directories for `SKILL.md` files at startup and provides
  a queryable catalog for Workers and the public API. Supports hot-reload
  via `reload/1` to pick up skills added or modified on disk without restart.

  ## Discovery Paths

  Skills are discovered from multiple directories. Later paths take precedence
  for name collisions (project-level overrides user-level):

  1. `~/.rlm/skills/`
  2. `~/.agents/skills/`
  3. Configured `skill_paths` (from `RLM.Config`)
  4. `<cwd>/.rlm/skills/`
  5. `<cwd>/.agents/skills/`

  ## Usage

      # List all skills (tier-1: name + description + path)
      RLM.SkillRegistry.catalog()

      # Get a specific skill with full body (tier-2)
      {:ok, skill} = RLM.SkillRegistry.get("visual-explainer")

      # Hot-reload after adding skills on disk
      RLM.SkillRegistry.reload()
  """

  use GenServer

  require Logger

  alias RLM.Skill

  # -- Public API --

  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Return the tier-1 catalog: sorted list of `%{name, description, path}` maps."
  @spec catalog(GenServer.server()) :: [
          %{name: String.t(), description: String.t(), path: String.t()}
        ]
  def catalog(server \\ __MODULE__) do
    GenServer.call(server, :catalog)
  end

  @doc "Return a specific skill by name (includes full body)."
  @spec get(GenServer.server(), String.t()) :: {:ok, Skill.t()} | :error
  def get(server \\ __MODULE__, name) do
    GenServer.call(server, {:get, name})
  end

  @doc "Return sorted list of all discovered skill names."
  @spec names(GenServer.server()) :: [String.t()]
  def names(server \\ __MODULE__) do
    GenServer.call(server, :names)
  end

  @doc "Rescan all configured paths. Non-blocking (cast)."
  @spec reload(GenServer.server()) :: :ok
  def reload(server \\ __MODULE__) do
    GenServer.cast(server, :reload)
  end

  @doc "Rescan with new paths, replacing the configured paths."
  @spec reload(GenServer.server(), [String.t()]) :: :ok
  def reload(server, paths) when is_list(paths) do
    GenServer.cast(server, {:reload, paths})
  end

  @doc "Return parse errors from the last scan."
  @spec errors(GenServer.server()) :: [{String.t(), String.t()}]
  def errors(server \\ __MODULE__) do
    GenServer.call(server, :errors)
  end

  # -- GenServer Callbacks --

  @impl true
  def init(opts) do
    extra_paths = Keyword.get(opts, :skill_paths, [])
    skip_defaults = Keyword.get(opts, :skip_default_paths, false)
    paths = if skip_defaults, do: extra_paths, else: build_paths(extra_paths)
    {skills, errors} = discover(paths)

    if map_size(skills) > 0 do
      Logger.info("SkillRegistry discovered #{map_size(skills)} skill(s)")
    end

    if errors != [] do
      Logger.warning("SkillRegistry encountered #{length(errors)} error(s) during scan")
    end

    {:ok, %{skills: skills, paths: paths, errors: errors}}
  end

  @impl true
  def handle_call(:catalog, _from, state) do
    catalog =
      state.skills
      |> Map.values()
      |> Enum.map(&Skill.catalog_entry/1)
      |> Enum.sort_by(& &1.name)

    {:reply, catalog, state}
  end

  @impl true
  def handle_call({:get, name}, _from, state) do
    {:reply, Map.fetch(state.skills, name), state}
  end

  @impl true
  def handle_call(:names, _from, state) do
    {:reply, state.skills |> Map.keys() |> Enum.sort(), state}
  end

  @impl true
  def handle_call(:errors, _from, state) do
    {:reply, state.errors, state}
  end

  @impl true
  def handle_cast(:reload, state) do
    {skills, errors} = discover(state.paths)
    {:noreply, %{state | skills: skills, errors: errors}}
  end

  @impl true
  def handle_cast({:reload, paths}, _state) do
    {skills, errors} = discover(paths)
    {:noreply, %{skills: skills, paths: paths, errors: errors}}
  end

  # -- Discovery --

  defp build_paths(extra_paths) do
    home = System.user_home!()

    user_paths = [
      Path.join(home, ".rlm/skills"),
      Path.join(home, ".agents/skills")
    ]

    project_paths =
      case File.cwd() do
        {:ok, cwd} ->
          [
            Path.join(cwd, ".rlm/skills"),
            Path.join(cwd, ".agents/skills")
          ]

        {:error, _} ->
          []
      end

    # Scan order: user → extra → project (last wins for name collisions)
    user_paths ++ extra_paths ++ project_paths
  end

  defp discover(paths) do
    Enum.reduce(paths, {%{}, []}, fn path, {skills, errors} ->
      expanded = Path.expand(path)

      if File.dir?(expanded) do
        scan_directory(expanded, skills, errors)
      else
        {skills, errors}
      end
    end)
  end

  defp scan_directory(dir_path, skills, errors) do
    case File.ls(dir_path) do
      {:ok, entries} ->
        Enum.reduce(entries, {skills, errors}, fn entry, {sk, er} ->
          full_path = Path.join(dir_path, entry)
          skill_md = Path.join(full_path, "SKILL.md")

          cond do
            not File.dir?(full_path) ->
              {sk, er}

            not File.regular?(skill_md) ->
              {sk, er}

            true ->
              case Skill.parse(skill_md) do
                {:ok, skill} ->
                  {Map.put(sk, skill.name, skill), er}

                {:error, reason} ->
                  {sk, [{skill_md, reason} | er]}
              end
          end
        end)

      {:error, reason} ->
        {skills, [{dir_path, "Could not list directory: #{inspect(reason)}"} | errors]}
    end
  end
end
