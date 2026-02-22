# examples/research_synthesis.exs
#
# Multi-Source Research Synthesis — exercises schema-mode direct queries,
# parallel_query fan-out, full subcall workers, multi-iteration reasoning,
# and mixed direct+subcall modes in the same run.
#
# Produces a rich trace in the web dashboard:
# - Root span with 4-5 iterations (extract, cross-reference, synthesize, finalize)
# - Fan-out of schema-mode direct queries (fast, leaf nodes)
# - Full subcall workers for deeper synthesis (with their own iterations)
# - Mix of direct queries and full subcalls visible as different node types
#
# Usage:
#   export CLAUDE_API_KEY=sk-ant-...
#   mix run examples/research_synthesis.exs
#
# Or via the Mix task:
#   mix rlm.examples research_synthesis

defmodule RLM.Examples.ResearchSynthesis do
  @moduledoc false

  @context """
  === SOURCE 1: Technical Report on Erlang/OTP ===
  Title: "Erlang/OTP: A Platform for Fault-Tolerant Distributed Systems"

  Erlang was created at Ericsson in the late 1980s by Joe Armstrong, Robert Virding,
  and Mike Williams. It was designed specifically for telecom switching systems that
  required 99.999% uptime (five nines). The key innovations were:

  1. Lightweight processes: Erlang processes are extremely cheap (300-400 bytes each),
     enabling millions of concurrent processes on a single machine.
  2. Message passing: Processes communicate only through asynchronous message passing,
     with no shared state, eliminating race conditions.
  3. Supervision trees: OTP's supervision model allows systems to self-heal by
     restarting failed processes according to configurable strategies.
  4. Hot code loading: Running systems can be upgraded without stopping, achieving
     true continuous availability.

  The BEAM virtual machine (Bogdan/Bjorn's Erlang Abstract Machine) provides
  preemptive scheduling with reduction counting, ensuring fair CPU distribution
  across all processes. The garbage collector runs per-process, avoiding system-wide
  GC pauses. Pattern matching in function heads enables concise, readable code.

  === SOURCE 2: Industry Analysis of Elixir Adoption ===
  Title: "Elixir in Production: Adoption Trends 2020-2025"

  Elixir, created by Jose Valim in 2011, brought modern language features to the
  BEAM platform. Key adoption milestones:

  - 2014: Phoenix framework 0.1 released, establishing Elixir as viable for web dev
  - 2016: Phoenix 1.0 with Channels (real-time WebSockets) — Discord adopts Elixir
  - 2018: LiveView announced — server-rendered reactive UIs without JavaScript
  - 2020: Nx (Numerical Elixir) project launched for ML/data science
  - 2022: Livebook reaches 1.0 — interactive notebooks for Elixir
  - 2024: Phoenix 1.8 with verified routes; growing AI/LLM ecosystem

  Notable production users: Discord (5M concurrent users per node), Pinterest
  (14x fewer servers after migration from Java), Bleacher Report (8x efficiency
  gain), PepsiCo (real-time demand forecasting), Brex (financial infrastructure).

  The language's sweet spots are: real-time systems, IoT backends, financial
  platforms, and any domain requiring high concurrency with fault tolerance.
  The main challenges remain: smaller ecosystem than Node.js/Python, steeper
  learning curve for OTP concepts, and limited ML/AI library maturity.

  === SOURCE 3: Academic Paper on Actor Model Implementations ===
  Title: "Comparing Actor Model Implementations: Erlang, Akka, and Orleans"

  The Actor Model, introduced by Carl Hewitt in 1973, defines computation in terms
  of actors that can: receive messages, create new actors, send messages, and
  designate behavior for the next message.

  Erlang/BEAM is the purest mainstream implementation. Unlike Akka (JVM) which maps
  actors to threads and requires explicit persistence plugins, Erlang processes are
  first-class VM constructs with built-in distribution (epmd). The BEAM's location
  transparency means the same code works whether processes are local or remote.

  Performance comparison (message throughput, 2024 benchmarks):
  - Erlang/BEAM: 2.1M msg/sec/core, 50μs p99 latency
  - Akka (JVM): 3.8M msg/sec/core, 120μs p99 latency (higher throughput, higher tail)
  - Orleans (.NET): 1.2M msg/sec/core, 200μs p99 latency

  Fault tolerance comparison:
  - Erlang: Built-in supervisors, process links, monitors. Crash recovery: <1ms
  - Akka: Supervisor strategies available but opt-in. Recovery: 5-50ms
  - Orleans: Grain activation/deactivation model. Recovery: 100-500ms

  The paper concludes that Erlang remains the gold standard for fault-tolerant
  distributed systems, while Akka offers better raw throughput for compute-heavy
  workloads, and Orleans excels at virtual actor patterns for cloud services.

  === SOURCE 4: Blog Post on RLM Architecture ===
  Title: "Building a Recursive Language Model Engine in Elixir"

  The RLM (Recursive Language Model) engine demonstrates how Elixir/OTP patterns
  naturally fit AI agent architectures:

  - Each LLM "node" is a GenServer (RLM.Worker) with its own state and iterate loop
  - Sub-calls spawn child Workers via DynamicSupervisor, forming a supervision tree
  - The async eval pattern prevents deadlock: eval runs in a spawned process so the
    Worker can handle {:spawn_subcall, ...} messages from eval'd code
  - Telemetry events provide observability into the LLM reasoning process
  - Phoenix LiveView dashboard renders execution traces in real-time

  Key insight: OTP's "let it crash" philosophy maps well to LLM agent error handling.
  When a sub-call fails or times out, the parent Worker can retry or try a different
  approach, just as a supervisor restarts a crashed child process.

  The three invariants (no raw data in LLM context, sub-outputs stay in variables,
  truncated stdout) mirror OTP's principle of process isolation — each Worker
  operates on its own state without leaking into others.
  """

  @query """
  Synthesize insights from multiple research sources using a structured approach:

  1. First, use parallel_query with schema mode to extract structured facts from each
     of the four sources in the context. Split the context by "=== SOURCE" markers to
     isolate each source. For each source, use this schema:
     %{"type" => "object", "properties" => %{
       "source_number" => %{"type" => "integer"},
       "title" => %{"type" => "string"},
       "source_type" => %{"type" => "string"},
       "key_claims" => %{"type" => "array", "items" => %{"type" => "string"}},
       "entities" => %{"type" => "array", "items" => %{"type" => "string"}},
       "quantitative_data" => %{"type" => "array", "items" => %{"type" => "string"}},
       "relevance_to_elixir" => %{"type" => "string"}
     }, "required" => ["source_number", "title", "source_type", "key_claims",
       "entities", "quantitative_data", "relevance_to_elixir"],
     "additionalProperties" => false}
     Store results in `source_extractions`.

  2. Next, use parallel_query with schema mode to perform cross-reference analysis.
     Create two cross-reference queries:

     a) **Agreement Analysis** — Pass summaries of all extractions and ask: which
        claims are supported by multiple sources? Schema:
        %{"type" => "object", "properties" => %{
          "corroborated_claims" => %{"type" => "array", "items" => %{"type" => "object",
            "properties" => %{
              "claim" => %{"type" => "string"},
              "supporting_sources" => %{"type" => "array", "items" => %{"type" => "integer"}}
            }, "required" => ["claim", "supporting_sources"], "additionalProperties" => false}},
          "unique_claims" => %{"type" => "array", "items" => %{"type" => "string"}}
        }, "required" => ["corroborated_claims", "unique_claims"],
        "additionalProperties" => false}

     b) **Contradiction Analysis** — Ask: are there any contradictions or tensions
        between the sources? Schema:
        %{"type" => "object", "properties" => %{
          "contradictions" => %{"type" => "array", "items" => %{"type" => "object",
            "properties" => %{
              "topic" => %{"type" => "string"},
              "source_a" => %{"type" => "integer"},
              "source_b" => %{"type" => "integer"},
              "description" => %{"type" => "string"}
            }, "required" => ["topic", "source_a", "source_b", "description"],
            "additionalProperties" => false}},
          "tensions" => %{"type" => "array", "items" => %{"type" => "string"}}
        }, "required" => ["contradictions", "tensions"],
        "additionalProperties" => false}

     Store results in `agreements` and `contradictions`.

  3. Then use a full lm_query subcall (without schema) to produce a narrative
     synthesis. Pass all extracted data, agreements, and contradictions as context.
     Ask the sub-model to write a 2-3 paragraph synthesis that:
     - Identifies the overarching narrative across all sources
     - Highlights the strongest corroborated claims
     - Notes any gaps or areas needing further research
     Store the result in `narrative`.

  4. Finally, set final_answer to a map:
     %{
       "sources_analyzed" => length of source_extractions (count),
       "total_claims" => total key_claims across all sources (count),
       "corroborated_claims" => number of corroborated claims,
       "contradictions_found" => number of contradictions,
       "key_entities" => deduplicated list of all entities across sources,
       "narrative" => the narrative synthesis string
     }
  """

  def run do
    IO.puts("\n  Multi-Source Research Synthesis")
    IO.puts("  ===============================\n")

    IO.puts("  Context: #{byte_size(@context)} bytes (4 research sources on Erlang/Elixir/BEAM)")
    IO.puts("  Launching RLM.run with max_depth: 3, max_iterations: 12...\n")

    case RLM.run(@context, @query, max_depth: 3, max_iterations: 12) do
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
    IO.puts("    Sources analyzed:     #{result["sources_analyzed"] || "?"}")
    IO.puts("    Total claims:         #{result["total_claims"] || "?"}")
    IO.puts("    Corroborated claims:  #{result["corroborated_claims"] || "?"}")
    IO.puts("    Contradictions found: #{result["contradictions_found"] || "?"}")

    entities = result["key_entities"] || []
    IO.puts("    Key entities (#{length(entities)}):")
    entities |> Enum.take(10) |> Enum.each(&IO.puts("      - #{&1}"))
    if length(entities) > 10, do: IO.puts("      ... and #{length(entities) - 10} more")

    if narrative = result["narrative"] do
      IO.puts("    Narrative preview:")
      narrative |> String.slice(0, 400) |> String.split("\n") |> Enum.each(&IO.puts("      #{&1}"))
      IO.puts("      ...")
    end
  end

  defp print_result(other) do
    IO.puts("  Result: #{inspect(other, limit: 500)}")
  end
end
