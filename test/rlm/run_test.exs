defmodule RLM.RunTest do
  use ExUnit.Case, async: true

  describe "deadlock prevention (compile-time invariant)" do
    test "RLM.Run only uses GenServer.call in allowlisted public API functions" do
      run_source =
        Path.join([__DIR__, "..", "..", "lib", "rlm", "run.ex"])
        |> Path.expand()
        |> File.read!()

      {:ok, ast} = Code.string_to_quoted(run_source)

      fns_with_call = functions_containing_genserver_call(ast)

      # Only these public API functions may use GenServer.call.
      # They call INTO the Run process (external callers → Run), which is safe.
      # Handler functions (handle_info, handle_cast) and private helpers
      # must use send/2 for Worker communication to prevent deadlocks.
      allowed = [:start_worker]

      violations = fns_with_call -- allowed

      assert violations == [],
             """
             DEADLOCK RISK: GenServer.call found in RLM.Run functions that must use send/2.

             Functions with GenServer.call: #{inspect(fns_with_call)}
             Allowed: #{inspect(allowed)}
             Violations: #{inspect(violations)}

             RLM.Run → RLM.Worker communication must ALWAYS use send/2 (never GenServer.call)
             to prevent Worker → Run → Worker deadlock cycles. If you need a new public API
             function that calls GenServer.call(run_pid, ...), add it to the allowlist above.
             """
    end
  end

  # Walk the module AST to find all function definitions containing GenServer.call
  defp functions_containing_genserver_call(ast) do
    {_, fns} =
      Macro.prewalk(ast, [], fn
        {def_type, _, [{name, _, _} | _]} = node, acc
        when def_type in [:def, :defp] and is_atom(name) ->
          if ast_contains_genserver_call?(node) do
            {node, [name | acc]}
          else
            {node, acc}
          end

        other, acc ->
          {other, acc}
      end)

    fns |> Enum.uniq() |> Enum.sort()
  end

  # Check if an AST subtree contains any GenServer.call invocation
  defp ast_contains_genserver_call?(ast) do
    {_, found?} =
      Macro.prewalk(ast, false, fn
        {{:., _, [{:__aliases__, _, [:GenServer]}, :call]}, _, _} = node, _acc ->
          {node, true}

        node, acc ->
          {node, acc}
      end)

    found?
  end
end
