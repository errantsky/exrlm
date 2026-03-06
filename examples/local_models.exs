# examples/local_models.exs
#
# Local Model Usage — demonstrates running RLM with local Ollama models
# instead of Anthropic's cloud API. No API key required.
#
# Prerequisites:
#   1. Install Ollama: https://ollama.com
#   2. Pull a model:
#        ollama pull qwen3:8b
#      Or any other model you prefer (llama3.2, mistral, etc.)
#   3. Ollama server must be running (it starts automatically after install)
#
# Usage:
#   mix run examples/local_models.exs
#
# Or via the Mix task:
#   mix rlm.examples local_models
#
# Configuration options shown:
#   - llm_module: RLM.LLM.Ollama (direct Ollama backend, no req_llm)
#   - models: %{large: "model-name", small: "model-name"} (bare Ollama model names)
#   - Using the same model for both large and small
#   - Using different models for parent vs subcall workers
#   - Overriding max_iterations for faster local runs

defmodule RLM.Examples.LocalModels do
  @moduledoc false

  # Change these to match the models you have pulled locally.
  # Run `ollama list` to see available models.
  # Use bare Ollama model names (no "ollama:" prefix needed).
  @default_model "qwen3:8b"

  def run do
    check_ollama!()

    model = System.get_env("RLM_LOCAL_MODEL", @default_model)
    IO.puts("\nRLM Local Models Example")
    IO.puts("========================")
    IO.puts("Using RLM.LLM.Ollama backend")
    IO.puts("Model: #{model}")
    IO.puts("")

    results =
      [
        {&test_basic_run/1, "Basic run"},
        {&test_multi_step/1, "Multi-step"},
        {&test_custom_model_map/1, "Custom model map"}
      ]
      |> Enum.map(fn {test_fn, name} ->
        IO.write("  Running: #{name}... ")

        case test_fn.(model) do
          {:ok, detail} ->
            IO.puts("PASS — #{detail}")
            {name, :pass}

          {:error, reason} ->
            IO.puts("FAIL — #{reason}")
            {name, :fail}
        end
      end)

    passes = Enum.count(results, fn {_, s} -> s == :pass end)
    fails = Enum.count(results, fn {_, s} -> s == :fail end)
    IO.puts("\n#{passes} passed, #{fails} failed out of #{length(results)} tests")

    if fails > 0, do: System.halt(1)
  end

  # ---------------------------------------------------------------------------
  # Tests
  # ---------------------------------------------------------------------------

  defp test_basic_run(model) do
    # Simplest usage: RLM.LLM.Ollama talks directly to the local Ollama server
    case RLM.run(
           "Elixir, Rust, Python",
           "Count the programming languages. Return the count as an integer.",
           llm_module: RLM.LLM.Ollama,
           models: %{large: model, small: model},
           max_iterations: 10
         ) do
      {:ok, 3, _run_id} ->
        {:ok, "counted 3 languages"}

      {:ok, other, _} ->
        {:error, "expected 3, got #{inspect(other)}"}

      {:error, reason} ->
        {:error, inspect(reason)}
    end
  end

  defp test_multi_step(model) do
    # Multi-step reasoning with a local model
    case RLM.run(
           "apple, banana, cherry",
           "First store the number of items in a variable called count. " <>
             "Then set final_answer to count * 100.",
           llm_module: RLM.LLM.Ollama,
           models: %{large: model, small: model},
           max_iterations: 10
         ) do
      {:ok, 300, _run_id} ->
        {:ok, "3 * 100 = 300"}

      {:ok, other, _} ->
        {:error, "expected 300, got #{inspect(other)}"}

      {:error, reason} ->
        {:error, inspect(reason)}
    end
  end

  defp test_custom_model_map(model) do
    # Demonstrate using different models for different roles.
    # In practice, you might use a larger model for the parent worker
    # and a smaller one for subcalls:
    #
    #   llm_module: RLM.LLM.Ollama,
    #   models: %{
    #     large: "qwen3:32b",
    #     small: "qwen3:8b",
    #     fast:  "qwen3:1.7b"
    #   }
    #
    # For this test, we use the same model for both to keep it simple.
    case RLM.run(
           "Hello",
           "Set final_answer to the string \"hello from local model\"",
           llm_module: RLM.LLM.Ollama,
           models: %{large: model, small: model},
           max_iterations: 5
         ) do
      {:ok, result, _run_id} when is_binary(result) ->
        {:ok, "got: #{String.slice(result, 0, 50)}"}

      {:ok, other, _} ->
        {:error, "expected string, got #{inspect(other)}"}

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

RLM.Examples.LocalModels.run()
