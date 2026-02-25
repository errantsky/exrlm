# examples/smoke_test.exs
#
# Live smoke test for the RLM engine. Requires CLAUDE_API_KEY.
#
# Usage:
#   export CLAUDE_API_KEY=sk-ant-...
#   mix run examples/smoke_test.exs
#
# Or via the Mix task:
#   mix rlm.smoke

defmodule RLM.SmokeTest do
  @moduledoc false

  def run do
    check_api_key!()

    results =
      [
        &test_basic_run/0,
        &test_multi_iteration/0,
        &test_schema_direct_query/0,
        &test_subcall/0,
        &test_interactive_session/0
      ]
      |> Enum.map(fn test_fn ->
        {name, result} = test_fn.()
        print_result(name, result)
        {name, result}
      end)

    print_summary(results)
  end

  # ---------------------------------------------------------------------------
  # Tests
  # ---------------------------------------------------------------------------

  defp test_basic_run do
    name = "Basic RLM.run"

    result =
      RLM.run(
        "Elixir, Rust, Python, Go",
        "Count the programming languages and return the count as an integer"
      )

    case result do
      {:ok, 4, _run_id} -> {name, :pass}
      {:ok, other, _} -> {name, {:fail, "expected 4, got #{inspect(other)}"}}
      {:error, reason} -> {name, {:fail, reason}}
    end
  end

  defp test_multi_iteration do
    name = "Multi-iteration (2 steps)"

    result =
      RLM.run(
        "apple, banana, cherry, date, elderberry",
        "First store the number of items in a variable called count. " <>
          "Then set final_answer to count * 10."
      )

    case result do
      {:ok, 50, _run_id} -> {name, :pass}
      {:ok, other, _} -> {name, {:fail, "expected 50, got #{inspect(other)}"}}
      {:error, reason} -> {name, {:fail, reason}}
    end
  end

  defp test_schema_direct_query do
    name = "Schema-mode lm_query (direct query)"

    result =
      RLM.run(
        "France",
        "Use lm_query with a schema to extract structured data about France. " <>
          "Call lm_query with the text \"What is the capital of France and its approximate " <>
          "population in millions?\" and schema: %{\"type\" => \"object\", \"properties\" => " <>
          "%{\"capital\" => %{\"type\" => \"string\"}, \"population_millions\" => " <>
          "%{\"type\" => \"number\"}}, \"required\" => [\"capital\", \"population_millions\"], " <>
          "\"additionalProperties\" => false}. " <>
          "Set final_answer to the result map.",
        max_depth: 3
      )

    case result do
      {:ok, %{"capital" => capital, "population_millions" => pop}, _run_id}
      when is_binary(capital) and is_number(pop) ->
        {name, {:pass, "#{capital}, #{pop}M"}}

      {:ok, other, _} ->
        {name, {:fail, "expected map with capital/population, got #{inspect(other)}"}}

      {:error, reason} ->
        {name, {:fail, reason}}
    end
  end

  defp test_subcall do
    name = "Subcall (lm_query without schema)"

    result =
      RLM.run(
        "The Elixir programming language was created by Jose Valim.",
        "Use lm_query to ask a sub-model: \"Who created Elixir?\" " <>
          "(pass just that question string, no schema). " <>
          "Set final_answer to the {:ok, response} tuple you get back.",
        max_depth: 3
      )

    case result do
      {:ok, {:ok, response}, _run_id} when is_binary(response) ->
        {name, {:pass, String.slice(response, 0, 60)}}

      {:ok, response, _run_id} when is_binary(response) ->
        {name, {:pass, String.slice(response, 0, 60)}}

      {:ok, other, _} ->
        {name, {:fail, "unexpected shape: #{inspect(other, limit: 200)}"}}

      {:error, reason} ->
        {name, {:fail, reason}}
    end
  end

  defp test_interactive_session do
    name = "Interactive session (keep-alive)"

    with {:ok, sid} <- RLM.start_session(cwd: "."),
         {:ok, answer1} <- RLM.send_message(sid, "Set x = 42 and return x as final_answer"),
         {:ok, answer2} <-
           RLM.send_message(sid, "Return x * 2 as final_answer (x should still be 42)") do
      cond do
        answer1 != 42 ->
          {name, {:fail, "turn 1: expected 42, got #{inspect(answer1)}"}}

        answer2 != 84 ->
          {name, {:fail, "turn 2: expected 84, got #{inspect(answer2)}"}}

        true ->
          {name, :pass}
      end
    else
      {:error, reason} -> {name, {:fail, reason}}
    end
  end

  # ---------------------------------------------------------------------------
  # Output
  # ---------------------------------------------------------------------------

  defp check_api_key! do
    case System.get_env("CLAUDE_API_KEY") do
      nil ->
        IO.puts("\n  ERROR: CLAUDE_API_KEY not set. Export it before running.\n")
        System.halt(1)

      key ->
        IO.puts("\nRLM Smoke Test")
        IO.puts("==============")
        IO.puts("API key: ...#{String.slice(key, -4, 4)}")
        IO.puts("")
    end
  end

  defp print_result(name, :pass) do
    IO.puts("  PASS  #{name}")
  end

  defp print_result(name, {:pass, detail}) do
    IO.puts("  PASS  #{name} — #{detail}")
  end

  defp print_result(name, {:fail, reason}) do
    IO.puts("  FAIL  #{name} — #{reason}")
  end

  defp print_summary(results) do
    {passes, fails} =
      Enum.split_with(results, fn
        {_, :pass} -> true
        {_, {:pass, _}} -> true
        _ -> false
      end)

    IO.puts("")
    IO.puts("#{length(passes)} passed, #{length(fails)} failed out of #{length(results)} tests")

    if fails != [] do
      IO.puts("")
      System.halt(1)
    end
  end
end

RLM.SmokeTest.run()
