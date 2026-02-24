defmodule Mix.Tasks.Rlm.Examples do
  use Boundary, classify_to: RLM
  @shortdoc "Run RLM example scenarios against the live Anthropic API"
  @moduledoc """
  Runs RLM example scenarios that exercise multi-iteration, subcall depth,
  parallel queries, schema-mode extraction, and filesystem tools.

  These produce rich execution traces viewable in the web dashboard
  (`mix phx.server` → http://localhost:4000).

  Requires the `CLAUDE_API_KEY` environment variable to be set.

  ## Usage

      # Run all examples
      mix rlm.examples

      # Run a specific example
      mix rlm.examples map_reduce
      mix rlm.examples code_review
      mix rlm.examples research_synthesis

      # List available examples
      mix rlm.examples --list
  """
  use Mix.Task

  @examples %{
    "map_reduce" => {
      "examples/map_reduce_analysis.exs",
      "RLM.Examples.MapReduceAnalysis",
      "Map-Reduce Text Analysis — parallel chunk analysis + synthesis"
    },
    "code_review" => {
      "examples/code_review.exs",
      "RLM.Examples.CodeReview",
      "Recursive Code Review — file tools + parallel schema analysis"
    },
    "research_synthesis" => {
      "examples/research_synthesis.exs",
      "RLM.Examples.ResearchSynthesis",
      "Multi-Source Research Synthesis — schema extraction + cross-reference"
    }
  }

  @impl true
  def run(args) do
    Mix.Task.run("app.start")

    cond do
      "--list" in args ->
        list_examples()

      args == [] ->
        run_all()

      true ->
        Enum.each(args, &run_example/1)
    end
  end

  defp list_examples do
    IO.puts("\nAvailable RLM Examples")
    IO.puts("======================\n")

    @examples
    |> Enum.sort()
    |> Enum.each(fn {name, {_file, _mod, desc}} ->
      IO.puts("  #{String.pad_trailing(name, 22)} #{desc}")
    end)

    IO.puts("\nUsage: mix rlm.examples [name ...]")
    IO.puts("       mix rlm.examples              (runs all)\n")
  end

  defp run_all do
    check_api_key!()

    IO.puts("\nRLM Examples — Full Suite")
    IO.puts("=========================")
    IO.puts("Running all #{map_size(@examples)} examples...\n")

    results =
      @examples
      |> Enum.sort()
      |> Enum.map(fn {name, _} -> {name, run_example(name)} end)

    print_summary(results)
  end

  defp run_example(name) do
    case Map.get(@examples, name) do
      nil ->
        IO.puts("\n  ERROR: Unknown example '#{name}'")
        IO.puts("  Run 'mix rlm.examples --list' to see available examples.\n")
        :unknown

      {file, mod_string, _desc} ->
        check_api_key!()
        script = resolve_script(file)

        if File.exists?(script) do
          Code.eval_file(script)
          # The module is now loaded; resolve it dynamically to avoid
          # compile-time warnings (modules only exist after eval_file)
          module = Module.concat(String.split(mod_string, "."))

          case apply(module, :run, []) do
            {:ok, run_id} ->
              IO.puts("\n  View trace: http://localhost:4000/runs/#{run_id}\n")
              :pass

            {:error, reason} ->
              IO.puts("\n  FAIL: #{inspect(reason, limit: 500)}\n")
              :fail
          end
        else
          IO.puts("\n  ERROR: Script not found at #{script}\n")
          :missing
        end
    end
  end

  defp resolve_script(relative) do
    Path.join(File.cwd!(), relative) |> Path.expand()
  end

  defp check_api_key! do
    case System.get_env("CLAUDE_API_KEY") do
      nil ->
        IO.puts("\n  ERROR: CLAUDE_API_KEY not set. Export it before running.\n")
        System.halt(1)

      key ->
        IO.puts("  API key: #{String.slice(key, 0, 12)}...")
    end
  end

  defp print_summary(results) do
    IO.puts("\n" <> String.duplicate("=", 50))

    {passes, others} =
      Enum.split_with(results, fn {_, status} -> status == :pass end)

    IO.puts(
      "#{length(passes)} passed, #{length(others)} failed out of #{length(results)} examples"
    )

    if others != [] do
      IO.puts("")

      Enum.each(others, fn {name, status} ->
        IO.puts("  #{status}  #{name}")
      end)

      IO.puts("")
    end
  end
end
