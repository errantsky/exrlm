# examples/map_reduce_analysis.exs
#
# Map-Reduce Text Analysis — exercises parallel subcalls, multi-iteration
# variable accumulation, chunking helpers, and depth-1 fan-out.
#
# Produces a rich trace in the web dashboard:
# - Root span with 3-4 iterations (chunk, fan-out, synthesize, finalize)
# - Multiple child spans from parallel_query (one per chunk)
# - Bindings growing across iterations
#
# Usage:
#   export CLAUDE_API_KEY=sk-ant-...
#   mix run examples/map_reduce_analysis.exs
#
# Or via the Mix task:
#   mix rlm.examples map_reduce

defmodule RLM.Examples.MapReduceAnalysis do
  @moduledoc false

  @context """
  ## The History of Computing: Key Milestones

  ### The Mechanical Era (1800s)
  Charles Babbage designed the Analytical Engine in 1837, widely considered the first
  general-purpose computer concept. Ada Lovelace wrote what is recognized as the first
  computer program for this machine — an algorithm to compute Bernoulli numbers. The
  engine was never completed due to funding and manufacturing limitations of the era,
  but its design anticipated many features of modern computers including loops,
  conditional branching, and memory.

  ### The Electromechanical Era (1930s-1940s)
  Alan Turing published "On Computable Numbers" in 1936, introducing the concept of
  the Turing machine — a mathematical model of computation that remains foundational
  to computer science. During World War II, Turing led the team at Bletchley Park that
  broke the Enigma code using the Bombe machine. Meanwhile, Konrad Zuse built the Z3
  in 1941, the first working programmable, fully automatic digital computer. In the US,
  ENIAC became operational in 1945, weighing 30 tons and using 18,000 vacuum tubes.

  ### The Transistor Revolution (1950s-1960s)
  The invention of the transistor at Bell Labs in 1947 by Bardeen, Brattain, and
  Shockley transformed computing. Jack Kilby and Robert Noyce independently invented
  the integrated circuit in 1958-1959, enabling dramatic miniaturization. IBM introduced
  the System/360 in 1964, the first family of computers designed to span a range of
  applications. COBOL and FORTRAN became the dominant programming languages, enabling
  non-specialists to write software for the first time.

  ### The Personal Computer Era (1970s-1980s)
  The Intel 4004, released in 1971, was the first commercial microprocessor. The Altair
  8800 in 1975 sparked the personal computer revolution. Steve Wozniak and Steve Jobs
  founded Apple Computer in 1976, releasing the Apple II in 1977. IBM introduced the PC
  in 1981, and Microsoft DOS became the standard operating system. The Macintosh launched
  in 1984 with its revolutionary graphical user interface. Tim Berners-Lee proposed the
  World Wide Web in 1989 while working at CERN.

  ### The Internet Age (1990s-2000s)
  The World Wide Web became publicly available in 1991. Mosaic, the first popular web
  browser, launched in 1993. Amazon, eBay, and Yahoo were founded in 1994-1995, beginning
  the dot-com era. Google was founded in 1998 by Larry Page and Sergey Brin. The dot-com
  bubble burst in 2000, but the internet continued to grow. Wikipedia launched in 2001.
  Facebook was founded in 2004, YouTube in 2005, and Twitter in 2006. The iPhone launched
  in 2007, beginning the smartphone revolution.

  ### The AI and Cloud Era (2010s-2020s)
  Cloud computing became mainstream with AWS, Azure, and Google Cloud. Deep learning
  breakthroughs in 2012 (AlexNet) reignited AI research. AlphaGo defeated the world
  champion in Go in 2016. GPT-3 demonstrated large language model capabilities in 2020.
  ChatGPT launched in November 2022, bringing AI to mainstream users. By 2024, AI was
  being integrated into search engines, productivity tools, and creative applications,
  raising both excitement about capabilities and concerns about safety and alignment.
  """

  @query """
  Analyze this historical text using a map-reduce approach:

  1. First, use chunks(context, 800) to split the context into manageable pieces and
     store them in a variable called `text_chunks` (convert the stream to a list).

  2. Then use parallel_query to analyze each chunk concurrently. For each chunk, ask
     the sub-model to extract: the era name, key people mentioned, key inventions/events,
     and the approximate decade range. Use the schema option with this JSON schema:
     %{"type" => "object",
       "properties" => %{
         "era" => %{"type" => "string"},
         "decade_range" => %{"type" => "string"},
         "key_people" => %{"type" => "array", "items" => %{"type" => "string"}},
         "key_events" => %{"type" => "array", "items" => %{"type" => "string"}}
       },
       "required" => ["era", "decade_range", "key_people", "key_events"],
       "additionalProperties" => false}
     Store the results in a variable called `chunk_analyses`.

  3. Then use lm_query (without schema) to synthesize all the extracted data into a
     cohesive timeline summary. Pass the chunk_analyses data as part of the query text.
     Store the synthesis result in `synthesis`.

  4. Finally, set final_answer to a map with keys "chunk_count", "total_people",
     "total_events", and "synthesis" — where total_people and total_events are the
     deduplicated counts across all chunks, and synthesis is the string from step 3.
  """

  def run do
    IO.puts("\n  Map-Reduce Text Analysis")
    IO.puts("  ========================\n")

    IO.puts("  Context: #{byte_size(@context)} bytes (history of computing)")
    IO.puts("  Launching RLM.run with max_depth: 3, max_iterations: 10...\n")

    case RLM.run(@context, @query, max_depth: 3, max_iterations: 10) do
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
    IO.puts("    Chunks analyzed: #{result["chunk_count"] || "?"}")
    IO.puts("    Unique people:   #{result["total_people"] || "?"}")
    IO.puts("    Unique events:   #{result["total_events"] || "?"}")

    if synth = result["synthesis"] do
      IO.puts("    Synthesis preview:")
      synth |> String.slice(0, 300) |> String.split("\n") |> Enum.each(&IO.puts("      #{&1}"))
      IO.puts("      ...")
    end
  end

  defp print_result(other) do
    IO.puts("  Result: #{inspect(other, limit: 500)}")
  end
end
