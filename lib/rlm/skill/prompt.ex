defmodule RLM.Skill.Prompt do
  @moduledoc """
  Pure functions for building skill-aware system prompt sections and activation messages.

  Separated from `RLM.Prompt` (which owns the base system prompt and feedback messages)
  to keep prompt assembly concerns modular.

  ## Progressive Disclosure

  - `catalog_section/1` builds the tier-1 catalog for the system prompt (~100 tokens per skill)
  - `activation_messages/1` builds tier-2 activation messages with full skill body
  """

  alias RLM.Skill

  @doc """
  Build the skill catalog section appended to the system prompt.

  Lists all available skills with name, description, and path so the model
  can activate them via `read_file(path)`. Returns an empty string when no
  skills are available.
  """
  @spec catalog_section([%{name: String.t(), description: String.t(), path: String.t()}]) ::
          String.t()
  def catalog_section([]), do: ""

  def catalog_section(entries) do
    lines =
      Enum.map_join(entries, "\n", fn %{name: name, description: desc, path: path} ->
        "- **#{name}** (`#{path}`): #{desc}"
      end)

    """

    ## Available Skills

    The following skills provide specialized instructions for specific tasks.
    When a task matches a skill's description, activate it by reading its SKILL.md:

    ```elixir
    {:ok, instructions} = read_file("<skill_path>")
    ```

    Then follow the instructions in the loaded content. Skills may reference
    additional files in their `scripts/`, `references/`, and `assets/` directories
    relative to the skill directory.

    #{lines}
    """
  end

  @doc """
  Build activation messages for pre-activated skills.

  Returns a list of `%{role: :user}` messages containing the full skill body
  and directory path. These are injected into the Worker's initial history
  before the task message, so the model sees them as context.
  """
  @spec activation_messages([Skill.t()]) :: [map()]
  def activation_messages([]), do: []

  def activation_messages(skills) do
    Enum.map(skills, fn %Skill{} = skill ->
      %{
        role: :user,
        content: """
        [Skill activated: #{skill.name}]

        #{skill.body}

        Skill directory: #{skill.dir}
        """
      }
    end)
  end
end
