defmodule RLM.Prompt do
  @moduledoc """
  System prompt loading and message formatting.
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

  @spec build_feedback_message(String.t(), :ok | :error) :: map()
  def build_feedback_message(truncated_stdout, eval_status) do
    status_text =
      if eval_status == :ok, do: "Code executed successfully.", else: "Code execution failed."

    content = """
    #{status_text}

    Stdout:
    ```
    #{truncated_stdout}
    ```

    Continue processing. When done, assign your answer to `final_answer`.
    """

    %{role: :user, content: content}
  end

  @spec build_nudge_message() :: map()
  def build_nudge_message do
    %{
      role: :user,
      content:
        "You seem to be repeating similar code. Try a different approach or set `final_answer` if you already have the result."
    }
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
    Always wrap your code in an ```elixir code block.
    """
  end
end
