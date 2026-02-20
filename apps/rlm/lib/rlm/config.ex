defmodule RLM.Config do
  @moduledoc """
  Configuration struct for RLM engine.
  Loads defaults from application env, allows runtime overrides.
  """

  defstruct [
    :api_base_url,
    :api_key,
    :model_large,
    :model_small,
    :max_iterations,
    :max_depth,
    :max_concurrent_subcalls,
    :context_window_tokens_large,
    :context_window_tokens_small,
    :truncation_head,
    :truncation_tail,
    :eval_timeout,
    :llm_timeout,
    :subcall_timeout,
    :cost_per_1k_prompt_tokens_large,
    :cost_per_1k_prompt_tokens_small,
    :cost_per_1k_completion_tokens_large,
    :cost_per_1k_completion_tokens_small,
    :enable_otel,
    :enable_event_log,
    :event_log_capture_full_stdout,
    :llm_module
  ]

  @type t :: %__MODULE__{}

  @spec load(keyword()) :: t()
  def load(overrides \\ []) do
    %__MODULE__{
      api_base_url: get(overrides, :api_base_url, "https://api.anthropic.com"),
      api_key: get(overrides, :api_key, System.get_env("CLAUDE_API_KEY")),
      model_large: get(overrides, :model_large, "claude-sonnet-4-5-20250929"),
      model_small: get(overrides, :model_small, "claude-haiku-4-5-20251001"),
      max_iterations: get(overrides, :max_iterations, 25),
      max_depth: get(overrides, :max_depth, 5),
      max_concurrent_subcalls: get(overrides, :max_concurrent_subcalls, 10),
      context_window_tokens_large: get(overrides, :context_window_tokens_large, 200_000),
      context_window_tokens_small: get(overrides, :context_window_tokens_small, 200_000),
      truncation_head: get(overrides, :truncation_head, 4000),
      truncation_tail: get(overrides, :truncation_tail, 4000),
      eval_timeout: get(overrides, :eval_timeout, 300_000),
      llm_timeout: get(overrides, :llm_timeout, 120_000),
      subcall_timeout: get(overrides, :subcall_timeout, 600_000),
      cost_per_1k_prompt_tokens_large: get(overrides, :cost_per_1k_prompt_tokens_large, 0.003),
      cost_per_1k_prompt_tokens_small: get(overrides, :cost_per_1k_prompt_tokens_small, 0.0008),
      cost_per_1k_completion_tokens_large:
        get(overrides, :cost_per_1k_completion_tokens_large, 0.015),
      cost_per_1k_completion_tokens_small:
        get(overrides, :cost_per_1k_completion_tokens_small, 0.004),
      enable_otel: get(overrides, :enable_otel, false),
      enable_event_log: get(overrides, :enable_event_log, true),
      event_log_capture_full_stdout: get(overrides, :event_log_capture_full_stdout, false),
      llm_module: get(overrides, :llm_module, RLM.LLM)
    }
  end

  defp get(overrides, key, default) do
    case Keyword.fetch(overrides, key) do
      {:ok, value} -> value
      :error -> Application.get_env(:rlm, key, default)
    end
  end
end
