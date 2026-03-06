defmodule RLM.Config do
  @moduledoc """
  Configuration struct for RLM engine.
  Loads defaults from application env, allows runtime overrides.

  ## Multi-Provider Model Map

  The `models` field maps symbolic keys to provider-prefixed model specs:

      %RLM.Config{
        models: %{
          large: "anthropic:claude-sonnet-4-6",
          small: "anthropic:claude-haiku-4-5"
        }
      }

  Model specs follow the `req_llm` naming convention: `"provider:model-name"`.
  For backward compatibility, bare model names without a provider prefix
  are treated as Anthropic models.

  ## Supported Providers

  Any provider supported by `req_llm`: Anthropic, OpenAI, Ollama (via vLLM),
  Google Gemini, Groq, and more. For local Ollama:

      RLM.run("data", "query",
        models: %{large: "ollama:qwen3.5:35b", small: "ollama:qwen3.5:9b"})
  """

  require Logger

  @default_context_window 128_000

  defstruct [
    :api_base_url,
    :api_key,
    # Legacy model fields — prefer `models` map
    :model_large,
    :model_small,
    :models,
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
    :enable_otel,
    :enable_event_log,
    :event_log_capture_full_stdout,
    :enable_replay_recording,
    :llm_module
  ]

  @type t :: %__MODULE__{}

  @spec load(keyword()) :: t()
  def load(overrides \\ []) do
    model_large = get(overrides, :model_large, "claude-sonnet-4-6")
    model_small = get(overrides, :model_small, "claude-haiku-4-5")

    default_models = %{
      large: model_large,
      small: model_small
    }

    %__MODULE__{
      api_base_url: get(overrides, :api_base_url, "https://api.anthropic.com"),
      api_key: get(overrides, :api_key, resolve_api_key()),
      model_large: model_large,
      model_small: model_small,
      models: get(overrides, :models, default_models),
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
      enable_otel: get(overrides, :enable_otel, false),
      enable_event_log: get(overrides, :enable_event_log, true),
      event_log_capture_full_stdout: get(overrides, :event_log_capture_full_stdout, false),
      enable_replay_recording: get(overrides, :enable_replay_recording, false),
      llm_module: get(overrides, :llm_module, RLM.LLM.ReqLLM)
    }
  end

  @doc """
  Resolve a model key to its spec string.

  Returns `{:ok, spec}` or `{:error, reason}`.

  ## Examples

      iex> config = RLM.Config.load(models: %{large: "anthropic:claude-sonnet-4-6"})
      iex> RLM.Config.resolve_model(config, :large)
      {:ok, "anthropic:claude-sonnet-4-6"}

      iex> config = RLM.Config.load()
      iex> RLM.Config.resolve_model(config, :unknown)
      {:error, "Unknown model key: unknown"}
  """
  @spec resolve_model(t(), atom()) :: {:ok, String.t()} | {:error, String.t()}
  def resolve_model(%__MODULE__{models: models}, key) when is_atom(key) do
    case Map.fetch(models, key) do
      {:ok, spec} when is_binary(spec) ->
        {:ok, spec}

      {:ok, other} ->
        {:error, "Model key #{key} has invalid spec: #{inspect(other)} (expected a string)"}

      :error ->
        {:error, "Unknown model key: #{key}"}
    end
  end

  @doc """
  Look up the context window size for a model key.

  Uses a two-tier strategy:
  1. Legacy `context_window_tokens_large/small` fields (for `:large`/`:small` keys)
  2. Default of #{@default_context_window} tokens for unknown models
  """
  @spec context_window_for(t(), atom()) :: non_neg_integer()
  def context_window_for(%__MODULE__{} = config, :large), do: config.context_window_tokens_large
  def context_window_for(%__MODULE__{} = config, :small), do: config.context_window_tokens_small
  def context_window_for(%__MODULE__{}, _key), do: @default_context_window

  defp resolve_api_key do
    case System.get_env("ANTHROPIC_API_KEY") do
      nil -> System.get_env("CLAUDE_API_KEY")
      key -> key
    end
  end

  defp get(overrides, key, default) do
    case Keyword.fetch(overrides, key) do
      {:ok, value} -> value
      :error -> Application.get_env(:rlm, key, default)
    end
  end
end
