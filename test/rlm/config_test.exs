defmodule RLM.ConfigTest do
  use ExUnit.Case, async: true

  alias RLM.Config

  describe "load/1" do
    test "returns a Config struct with expected defaults" do
      config = Config.load()

      assert %Config{} = config
      assert config.llm_module == RLM.LLM.ReqLLM
      assert config.max_iterations == 25
      assert config.max_depth == 5
    end

    test "builds default models map from model_large/model_small" do
      config = Config.load()

      assert config.models == %{
               large: "claude-sonnet-4-6",
               small: "claude-haiku-4-5"
             }
    end

    test "overrides models map when provided" do
      custom_models = %{large: "ollama:llama3", small: "ollama:llama3:8b"}
      config = Config.load(models: custom_models)

      assert config.models == custom_models
    end

    test "legacy model_large/model_small flow into default models map" do
      config = Config.load(model_large: "custom-large", model_small: "custom-small")

      assert config.models == %{large: "custom-large", small: "custom-small"}
      assert config.model_large == "custom-large"
      assert config.model_small == "custom-small"
    end

    test "explicit models override takes precedence over legacy fields" do
      config =
        Config.load(
          model_large: "ignored-large",
          models: %{large: "winner-large", small: "winner-small"}
        )

      assert config.models == %{large: "winner-large", small: "winner-small"}
    end

    test "llm_module defaults to RLM.LLM.ReqLLM" do
      config = Config.load()
      assert config.llm_module == RLM.LLM.ReqLLM
    end

    test "llm_module can be overridden" do
      config = Config.load(llm_module: RLM.LLM.Anthropic)
      assert config.llm_module == RLM.LLM.Anthropic
    end
  end

  describe "resolve_model/2" do
    test "returns {:ok, spec} for a valid key" do
      config = Config.load(models: %{large: "anthropic:claude-sonnet-4-6"})

      assert {:ok, "anthropic:claude-sonnet-4-6"} = Config.resolve_model(config, :large)
    end

    test "returns {:ok, spec} for bare model name" do
      config = Config.load()

      assert {:ok, "claude-sonnet-4-6"} = Config.resolve_model(config, :large)
      assert {:ok, "claude-haiku-4-5"} = Config.resolve_model(config, :small)
    end

    test "returns {:error, _} for unknown key" do
      config = Config.load()

      assert {:error, message} = Config.resolve_model(config, :unknown)
      assert message =~ "Unknown model key: unknown"
    end

    test "returns {:error, _} for non-string value in models map" do
      config = Config.load(models: %{large: 42, small: "valid"})

      assert {:error, message} = Config.resolve_model(config, :large)
      assert message =~ "invalid spec"
      assert message =~ "42"
    end

    test "works with custom model keys" do
      config = Config.load(models: %{large: "a", small: "b", medium: "ollama:qwen3:14b"})

      assert {:ok, "ollama:qwen3:14b"} = Config.resolve_model(config, :medium)
    end
  end

  describe "context_window_for/2" do
    test "returns context_window_tokens_large for :large" do
      config = Config.load(context_window_tokens_large: 200_000)

      assert Config.context_window_for(config, :large) == 200_000
    end

    test "returns context_window_tokens_small for :small" do
      config = Config.load(context_window_tokens_small: 100_000)

      assert Config.context_window_for(config, :small) == 100_000
    end

    test "returns default 128_000 for unknown model keys" do
      config = Config.load()

      import ExUnit.CaptureLog
      log = capture_log(fn -> assert Config.context_window_for(config, :medium) == 128_000 end)
      assert log =~ "No context window configured for model key :medium"
    end
  end

  describe "resolve_api_key (via load)" do
    test "api_key can be explicitly set" do
      config = Config.load(api_key: "test-key-123")
      assert config.api_key == "test-key-123"
    end
  end
end
