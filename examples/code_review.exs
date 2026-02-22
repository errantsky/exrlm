# examples/code_review.exs
#
# Recursive Code Review — exercises filesystem tools (read_file), multiple
# lm_query subcalls at depth 1-2, schema-mode extraction, multi-iteration
# reasoning, and variable accumulation.
#
# Produces a rich trace in the web dashboard:
# - Root span with 4-5 iterations (discover, read, analyze, aggregate, finalize)
# - Multiple child spans from subcalls (one per analysis aspect)
# - Mix of schema-mode direct queries and full subcall workers
# - Filesystem tool usage visible in code blocks
#
# Usage:
#   export CLAUDE_API_KEY=sk-ant-...
#   mix run examples/code_review.exs
#
# Or via the Mix task:
#   mix rlm.examples code_review

defmodule RLM.Examples.CodeReview do
  @moduledoc false

  # We'll review the RLM.Sandbox module — it's a good size and has varied patterns
  @target_file "apps/rlm/lib/rlm/sandbox.ex"

  @query """
  Perform a thorough code review of an Elixir source file by following these steps:

  1. First, use read_file to read the file at the path stored in context.
     Store the file contents in a variable called `source_code`.
     Also count the lines and store in `line_count`.

  2. Next, run THREE parallel sub-analyses using parallel_query. For each, pass the
     full source code as context in the query text. Use the schema option for structured
     results. The three analyses are:

     a) **Structure Analysis** — Ask the sub-model to identify all public functions,
        their arities, and group them by category (helpers, LLM calls, filesystem, etc.).
        Schema: %{"type" => "object", "properties" => %{
          "module_name" => %{"type" => "string"},
          "function_groups" => %{"type" => "array", "items" => %{"type" => "object",
            "properties" => %{
              "category" => %{"type" => "string"},
              "functions" => %{"type" => "array", "items" => %{"type" => "string"}}
            }, "required" => ["category", "functions"], "additionalProperties" => false}},
          "total_public_functions" => %{"type" => "integer"}
        }, "required" => ["module_name", "function_groups", "total_public_functions"],
        "additionalProperties" => false}

     b) **Quality Analysis** — Ask the sub-model to evaluate code quality: documentation
        coverage, consistent naming, error handling patterns, and potential improvements.
        Schema: %{"type" => "object", "properties" => %{
          "documentation_score" => %{"type" => "integer"},
          "naming_consistency" => %{"type" => "integer"},
          "error_handling_score" => %{"type" => "integer"},
          "strengths" => %{"type" => "array", "items" => %{"type" => "string"}},
          "improvements" => %{"type" => "array", "items" => %{"type" => "string"}}
        }, "required" => ["documentation_score", "naming_consistency",
          "error_handling_score", "strengths", "improvements"],
        "additionalProperties" => false}

     c) **Pattern Analysis** — Ask the sub-model to identify design patterns, OTP
        patterns, and any anti-patterns in the code.
        Schema: %{"type" => "object", "properties" => %{
          "patterns_used" => %{"type" => "array", "items" => %{"type" => "string"}},
          "otp_patterns" => %{"type" => "array", "items" => %{"type" => "string"}},
          "anti_patterns" => %{"type" => "array", "items" => %{"type" => "string"}},
          "overall_assessment" => %{"type" => "string"}
        }, "required" => ["patterns_used", "otp_patterns", "anti_patterns",
          "overall_assessment"], "additionalProperties" => false}

     Store the three results in `structure_analysis`, `quality_analysis`, and
     `pattern_analysis` respectively.

  3. Then use a single lm_query subcall (without schema) to write a cohesive review
     summary that synthesizes all three analyses into an executive summary with
     specific, actionable recommendations. Pass summaries of the three analyses as
     context text. Store the result in `review_summary`.

  4. Finally, set final_answer to a map with these keys:
     - "file" — the file path
     - "line_count" — number of lines
     - "structure" — the structure analysis map
     - "quality" — the quality analysis map
     - "patterns" — the pattern analysis map
     - "summary" — the synthesized review string
  """

  def run do
    IO.puts("\n  Recursive Code Review")
    IO.puts("  =====================\n")

    # Find the absolute path to the target file
    file_path = Path.expand(@target_file, File.cwd!())

    unless File.exists?(file_path) do
      IO.puts("  SKIP  Target file not found: #{file_path}")
      {:error, "file not found"}
    else
      IO.puts("  Target: #{@target_file}")
      IO.puts("  Launching RLM.run with max_depth: 3, max_iterations: 12...\n")

      case RLM.run(file_path, @query, max_depth: 3, max_iterations: 12, cwd: File.cwd!()) do
        {:ok, result, run_id} ->
          IO.puts("  PASS  run_id: #{run_id}")
          print_result(result)
          {:ok, run_id}

        {:error, reason} ->
          IO.puts("  FAIL  #{inspect(reason, limit: 500)}")
          {:error, reason}
      end
    end
  end

  defp print_result(result) when is_map(result) do
    IO.puts("  Results:")
    IO.puts("    File:       #{result["file"] || "?"}")
    IO.puts("    Lines:      #{result["line_count"] || "?"}")

    if structure = result["structure"] do
      IO.puts("    Functions:  #{structure["total_public_functions"] || "?"}")

      groups = structure["function_groups"] || []

      Enum.each(groups, fn group ->
        fns = group["functions"] || []
        IO.puts("      #{group["category"]}: #{Enum.join(fns, ", ")}")
      end)
    end

    if quality = result["quality"] do
      IO.puts("    Quality scores:")
      IO.puts("      Documentation:   #{quality["documentation_score"]}/10")
      IO.puts("      Naming:          #{quality["naming_consistency"]}/10")
      IO.puts("      Error handling:  #{quality["error_handling_score"]}/10")
      IO.puts("    Strengths: #{Enum.join(quality["strengths"] || [], "; ")}")
      IO.puts("    Improvements: #{Enum.join(quality["improvements"] || [], "; ")}")
    end

    if patterns = result["patterns"] do
      IO.puts("    Patterns: #{Enum.join(patterns["patterns_used"] || [], ", ")}")
      IO.puts("    Assessment: #{patterns["overall_assessment"] || "?"}")
    end

    if summary = result["summary"] do
      IO.puts("    Summary preview:")
      summary |> String.slice(0, 300) |> String.split("\n") |> Enum.each(&IO.puts("      #{&1}"))
      IO.puts("      ...")
    end
  end

  defp print_result(other) do
    IO.puts("  Result: #{inspect(other, limit: 500)}")
  end
end
