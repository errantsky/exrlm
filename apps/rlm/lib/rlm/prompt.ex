defmodule RLM.Prompt do
  @moduledoc """
  System prompt loading and message formatting.

  Feedback messages use structured JSON so the LLM receives machine-parseable
  eval results alongside its own JSON-schema-constrained responses.
  """

  @spec system_prompt() :: String.t()
  def system_prompt do
    path = Application.app_dir(:rlm, "priv/system_prompt.md")

    case File.read(path) do
      {:ok, content} -> content
      {:error, _} -> default_system_prompt()
    end
  end

  @spec build_system_message() :: map()
  def build_system_message do
    %{role: :system, content: system_prompt()}
  end

  @spec build_user_message(String.t(), non_neg_integer(), non_neg_integer(), String.t()) :: map()
  def build_user_message(query, context_bytes, context_lines, context_preview) do
    content = """
    Your task: #{query}

    The variable `context` contains the input data.
    - Size: #{context_bytes} bytes, #{context_lines} lines
    - Preview (first 500 chars):
    ```
    #{context_preview}
    ```

    Write Elixir code to process `context`. When you have the final answer, assign it to `final_answer`.
    """

    %{role: :user, content: content}
  end

  @doc """
  Build a structured JSON feedback message after code evaluation.

  Returns a `%{role: :user, content: json_string}` map with fields:
  - `eval_status` — `"ok"` or `"error"`
  - `stdout` / `error_output` — truncated output from eval
  - `bindings` — current variable bindings summary
  - `final_answer_set` — whether `final_answer` was assigned
  """
  @spec build_feedback_message(String.t(), :ok | :error, list(), boolean()) :: map()
  def build_feedback_message(truncated_output, eval_status, bindings_info, final_answer_set) do
    payload =
      case eval_status do
        :ok ->
          %{
            "eval_status" => "ok",
            "stdout" => truncated_output,
            "bindings" => format_bindings(bindings_info),
            "final_answer_set" => final_answer_set
          }

        :error ->
          %{
            "eval_status" => "error",
            "error_output" => truncated_output,
            "bindings" => format_bindings(bindings_info),
            "final_answer_set" => false
          }
      end

    %{role: :user, content: Jason.encode!(payload)}
  end

  @doc "Build feedback for when the LLM returned empty code."
  @spec build_empty_code_feedback() :: map()
  def build_empty_code_feedback do
    payload = %{
      "eval_status" => "skipped",
      "message" => "The code field was empty. Provide Elixir code to execute."
    }

    %{role: :user, content: Jason.encode!(payload)}
  end

  @spec build_nudge_message() :: map()
  def build_nudge_message do
    payload = %{
      "eval_status" => "nudge",
      "message" =>
        "You are repeating similar code. Try a different approach or set final_answer."
    }

    %{role: :user, content: Jason.encode!(payload)}
  end

  @spec build_compaction_addendum(String.t()) :: String.t()
  def build_compaction_addendum(preview) do
    """
    [History compacted. Previous conversation summary available in `compacted_history` binding.]

    Preview of compacted history:
    ```
    #{preview}
    ```

    Continue working on the original task. Your bindings are preserved.
    """
  end

  defp format_bindings(bindings_info) when is_list(bindings_info) do
    Enum.map(bindings_info, fn
      {name, type, bytes} ->
        %{"name" => to_string(name), "type" => to_string(type), "bytes" => bytes}

      other ->
        %{"info" => inspect(other)}
    end)
  end

  defp format_bindings(_), do: []

  defp default_system_prompt do
    """
    You are an RLM (Recursive Language Model) agent running inside an Elixir REPL.

    ## Three Invariants
    1. The input data is stored in the `context` variable. You NEVER see the raw data — only metadata and a preview.
    2. Sub-LLM outputs are stored in variables. You never see sub-call results in your context window.
    3. Stdout is truncated. Store important results in variables.

    ## Your Capabilities
    - Write Elixir code that will be evaluated in a persistent REPL
    - All bindings persist across iterations
    - You can call `lm_query(text, model_size: :small)` to delegate to a sub-LLM
    - You can call `parallel_query(inputs, model_size: :small)` for concurrent sub-LLM calls

    ## Helper Functions
    - `chunks(string, size)` — lazily split a string into chunks of `size` characters
    - `grep(pattern, string)` — return `{line_number, line}` tuples matching a substring or regex
    - `preview(term, n \\\\ 500)` — truncated representation of any term
    - `list_bindings()` — return names, types, and sizes of all current bindings
    - `parallel_query(inputs, opts \\\\ [model_size: :small])` — invoke multiple sub-LLMs concurrently

    ## Concurrency
    Prefer `parallel_query` over sequential `lm_query` when processing multiple chunks.

    ## Termination
    Set `final_answer = <your result>` when done. The REPL will detect this and return the answer.

    ## Output Format
    Your response is a JSON object with two fields:
    - `reasoning`: your explanation and thought process
    - `code`: Elixir code to execute (use empty string "" if you need to think without executing)

    After each code execution you receive structured JSON feedback with `eval_status`, `stdout`, and `bindings`.
    """
  end
end
