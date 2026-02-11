import Config

config :rlm,
  api_base_url: "https://api.anthropic.com",
  model_large: "claude-sonnet-4-5-20250929",
  model_small: "claude-haiku-4-5-20251001"

config :logger, :default_handler,
  level: :info

if config_env() == :test do
  config :logger, :default_handler,
    level: :warning
end
