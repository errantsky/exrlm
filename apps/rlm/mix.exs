defmodule RLM.MixProject do
  use Mix.Project

  def project do
    [
      app: :rlm,
      version: "0.2.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      aliases: aliases(),
      name: "RLM",
      source_url: "https://github.com/errantsky/exrlm",
      docs: docs()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {RLM.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      # HTTP client
      {:req, "~> 0.5"},
      {:jason, "~> 1.4"},

      # Telemetry
      {:telemetry, "~> 1.2"},

      # PubSub (used by core for event broadcasting)
      {:phoenix_pubsub, "~> 2.1"},

      # Test
      {:mox, "~> 1.0", only: :test},

      # Docs
      {:ex_doc, "~> 0.40.1", only: :dev, runtime: false}
    ]
  end

  defp aliases do
    []
  end

  defp docs do
    [
      main: "readme",
      extras: [
        "../../README.md": [title: "Overview"],
        "../../CHANGELOG.md": [title: "Changelog"]
      ],
      groups_for_modules: [
        "RLM Engine": [
          RLM,
          RLM.Config,
          RLM.Worker,
          RLM.Eval,
          RLM.Sandbox,
          RLM.LLM,
          RLM.Prompt,
          RLM.Helpers,
          RLM.Truncate,
          RLM.Span,
          RLM.EventLog,
          RLM.EventLog.Sweeper,
          RLM.TraceStore,
          RLM.IEx,
          RLM.Node
        ],
        "Filesystem Tools": [
          RLM.Tool,
          RLM.ToolRegistry,
          RLM.Tools.ReadFile,
          RLM.Tools.WriteFile,
          RLM.Tools.EditFile,
          RLM.Tools.Bash,
          RLM.Tools.Grep,
          RLM.Tools.Glob,
          RLM.Tools.Ls
        ],
        Telemetry: [
          RLM.Telemetry,
          RLM.Telemetry.Logger,
          RLM.Telemetry.PubSub,
          RLM.Telemetry.EventLogHandler
        ]
      ]
    ]
  end
end
