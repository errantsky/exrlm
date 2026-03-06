# examples/skills_ollama.exs
#
# Agent Skills + Ollama — demonstrates skill activation with local models.
# No API key required — uses RLM.LLM.Ollama to talk to a local Ollama server.
#
# This example:
#   1. Creates a temporary skill on disk
#   2. Reloads the SkillRegistry to discover it
#   3. Runs RLM with the skill activated via `skills: ["skill-name"]`
#   4. Verifies the skill's instructions reached the LLM
#
# Prerequisites:
#   1. Install Ollama: https://ollama.com
#   2. Pull a model:  ollama pull qwen3:8b
#   3. Ollama server must be running
#
# Usage:
#   mix run examples/skills_ollama.exs
#   mix rlm.examples skills_ollama

defmodule RLM.Examples.SkillsOllama do
  @moduledoc false

  @default_model "qwen3:8b"

  def run do
    check_ollama!()

    model = System.get_env("RLM_LOCAL_MODEL", @default_model)
    IO.puts("\n  Agent Skills + Ollama Example")
    IO.puts("  ==============================")
    IO.puts("  Model: #{model}\n")

    # Create a temporary skill directory with a test skill
    tmp_dir = Path.join(System.tmp_dir!(), "rlm_skills_example_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(tmp_dir)

    try do
      install_test_skill(tmp_dir)

      # Reload the global SkillRegistry with our temp path so it discovers the skill
      RLM.SkillRegistry.reload(RLM.SkillRegistry, [tmp_dir])
      :sys.get_state(RLM.SkillRegistry)

      skills = RLM.SkillRegistry.names()
      IO.puts("  Discovered skills: #{inspect(skills)}")

      results =
        [
          {&test_basic_no_skills/1, "Basic run (no skills)"},
          {&test_with_skill/1, "Run with analysis-style skill activated"}
        ]
        |> Enum.map(fn {test_fn, name} ->
          IO.write("    #{name}... ")

          case test_fn.(model) do
            {:ok, detail, run_id} ->
              IO.puts("PASS — #{detail}")
              {name, :pass, run_id}

            {:error, reason} ->
              IO.puts("FAIL — #{reason}")
              {name, :fail, nil}
          end
        end)

      passes = Enum.count(results, fn {_, s, _} -> s == :pass end)
      fails = Enum.count(results, fn {_, s, _} -> s == :fail end)
      IO.puts("\n  #{passes} passed, #{fails} failed out of #{length(results)} tests")

      if fails == 0 do
        {_, _, run_id} = List.last(results)
        {:ok, run_id}
      else
        {:error, "#{fails} of #{length(results)} skills+ollama tests failed"}
      end
    after
      # Clean up: restore empty skill paths and remove temp directory
      RLM.SkillRegistry.reload(RLM.SkillRegistry, [])
      :sys.get_state(RLM.SkillRegistry)
      File.rm_rf!(tmp_dir)
    end
  end

  # ---------------------------------------------------------------------------
  # Skill installation
  # ---------------------------------------------------------------------------

  defp install_test_skill(base_dir) do
    skill_dir = Path.join(base_dir, "structured-analysis")
    File.mkdir_p!(skill_dir)

    # A simple analysis skill that instructs the LLM to structure its
    # response around strengths, weaknesses, and a recommendation.
    File.write!(Path.join(skill_dir, "SKILL.md"), """
    ---
    name: structured-analysis
    description: >
      Analyze topics using a structured framework: identify strengths,
      weaknesses, and provide a concrete recommendation.
    ---

    # Structured Analysis Framework

    When analyzing any topic, structure your work as follows:

    1. **Strengths** — identify 2-3 key strengths or advantages
    2. **Weaknesses** — identify 2-3 key weaknesses or risks
    3. **Recommendation** — provide a concrete, actionable recommendation

    Store each section in a variable before composing the final answer.
    The final_answer should be a single string combining all three sections.
    """)

    IO.puts("  Installed skill: structured-analysis")
  end

  # ---------------------------------------------------------------------------
  # Tests
  # ---------------------------------------------------------------------------

  defp test_basic_no_skills(model) do
    # Baseline: RLM works with Ollama without any skills activated
    case RLM.run(
           "Elixir, Python, Go",
           "Count the programming languages listed. Set final_answer to the count.",
           llm_module: RLM.LLM.Ollama,
           models: %{large: model, small: model},
           max_iterations: 10
         ) do
      {:ok, 3, run_id} ->
        {:ok, "counted 3 languages", run_id}

      {:ok, other, run_id} ->
        {:error, "expected 3, got #{inspect(other)} (run: #{run_id})"}

      {:error, reason} ->
        {:error, inspect(reason)}
    end
  end

  defp test_with_skill(model) do
    # With skill activated: the structured-analysis skill's instructions
    # are injected into the worker's message history before the task.
    # The LLM should follow the skill's framework.
    case RLM.run(
           "Elixir is a functional, concurrent programming language built on the BEAM VM.",
           "Analyze Elixir as a programming language choice for building web APIs.",
           llm_module: RLM.LLM.Ollama,
           models: %{large: model, small: model},
           max_iterations: 15,
           skills: ["structured-analysis"]
         ) do
      {:ok, result, run_id} when is_binary(result) and byte_size(result) > 50 ->
        {:ok, "got #{byte_size(result)} byte analysis", run_id}

      {:ok, result, run_id} ->
        {:error, "expected substantive string, got #{inspect(result)} (run: #{run_id})"}

      {:error, reason} ->
        {:error, inspect(reason)}
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp check_ollama! do
    case System.cmd("which", ["ollama"], stderr_to_stdout: true) do
      {_, 0} ->
        :ok

      _ ->
        IO.puts("""

          Ollama not found. Install it from https://ollama.com

          After installing, pull a model:
            ollama pull qwen3:8b

        """)

        System.halt(1)
    end
  end
end

RLM.Examples.SkillsOllama.run()
