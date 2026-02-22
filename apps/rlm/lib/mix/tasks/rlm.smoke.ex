defmodule Mix.Tasks.Rlm.Smoke do
  @shortdoc "Run live smoke tests against the Anthropic API"
  @moduledoc """
  Runs the RLM smoke test suite against the live Anthropic API.

  Requires the `CLAUDE_API_KEY` environment variable to be set.

  ## Usage

      mix rlm.smoke

  This delegates to `examples/smoke_test.exs` at the umbrella root.
  """
  use Mix.Task

  @impl true
  def run(_args) do
    Mix.Task.run("app.start")

    script =
      [Mix.Project.deps_paths()[:rlm] || "", "..", "..", "examples", "smoke_test.exs"]
      |> Path.join()
      |> Path.expand()

    if File.exists?(script) do
      Code.eval_file(script)
    else
      Mix.shell().error("Smoke test script not found at #{script}")
      exit({:shutdown, 1})
    end
  end
end
