# examples/web_fetch.exs
#
# Web Fetch & JSON Processing — exercises bash tool with curl and jq,
# schema-mode extraction, and multi-iteration reasoning.
#
# Produces a trace in the web dashboard:
# - Root span with 3-5 iterations (fetch, parse, analyze, summarize)
# - curl/jq commands visible in code blocks
# - Schema-mode extraction for structured output
#
# Uses the public GitHub API (no auth required, 60 requests/hour limit).
#
# Usage:
#   export CLAUDE_API_KEY=sk-ant-...
#   mix run examples/web_fetch.exs
#
# Or via the Mix task:
#   mix rlm.examples web_fetch

defmodule RLM.Examples.WebFetch do
  @moduledoc false

  @query """
  Fetch and analyze public repository data from the GitHub API using curl and jq.

  Follow these steps:

  1. Use bash() with curl to fetch the top 5 most-starred Elixir repositories from
     the GitHub search API. The endpoint is:
       https://api.github.com/search/repositories?q=language:elixir&sort=stars&per_page=5
     Use the flags: -sS -L -H 'Accept: application/json'
     Pipe the output through jq to extract just the repository names, star counts,
     and descriptions:
       jq '[.items[] | {name: .full_name, stars: .stargazers_count, description: .description}]'
     Store the parsed JSON string in a variable called `repos_json`.

  2. Parse the JSON string into an Elixir data structure using Jason.decode!/1.
     Store it in `repos`. Print a summary of what you found.

  3. For each repository, use a schema-mode lm_query to generate a one-sentence
     summary of what the project does based on its name and description. Use
     parallel_query with schema mode for efficiency. The schema should be:
       %{"type" => "object",
         "properties" => %{"summary" => %{"type" => "string"}},
         "required" => ["summary"], "additionalProperties" => false}
     Store the results in `summaries`.

  4. Set final_answer to a map with:
     - "repos" — the list of repo maps (name, stars, description)
     - "summaries" — list of generated summary strings
     - "count" — number of repos fetched
  """

  def run do
    IO.puts("\n  Web Fetch & JSON Processing")
    IO.puts("  ============================\n")
    IO.puts("  Fetching top Elixir repos from GitHub API via curl + jq...")
    IO.puts("  Launching RLM.run with max_iterations: 10...\n")

    case RLM.run("", @query, max_iterations: 10, cwd: File.cwd!()) do
      {:ok, result, run_id} ->
        IO.puts("  PASS  run_id: #{run_id}")
        print_result(result)
        {:ok, run_id}

      {:error, reason} ->
        IO.puts("  FAIL  #{inspect(reason, limit: 500)}")
        {:error, reason}
    end
  end

  defp print_result(result) when is_map(result) do
    IO.puts("  Results:")
    IO.puts("    Repos fetched: #{result["count"] || "?"}")

    repos = result["repos"] || []

    Enum.each(repos, fn repo ->
      IO.puts("    - #{repo["name"]} (#{repo["stars"]} stars)")
      IO.puts("      #{String.slice(repo["description"] || "", 0, 80)}")
    end)

    summaries = result["summaries"] || []

    if summaries != [] do
      IO.puts("    Summaries:")

      Enum.each(summaries, fn s ->
        text = if is_map(s), do: s["summary"] || inspect(s), else: to_string(s)
        IO.puts("      - #{String.slice(text, 0, 100)}")
      end)
    end
  end

  defp print_result(other) do
    IO.puts("  Result: #{inspect(other, limit: 500)}")
  end
end
