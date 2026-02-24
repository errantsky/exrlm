defmodule RLM.MixProject do
  use Mix.Project

  def project do
    [
      app: :rlm,
      version: "0.3.0",
      elixir: "~> 1.19",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      compilers: [:boundary, :phoenix_live_view] ++ Mix.compilers(),
      listeners: [Phoenix.CodeReloader],
      name: "RLM",
      source_url: "https://github.com/errantsky/exrlm",
      docs: docs()
    ]
  end

  def application do
    [
      mod: {RLM.Application, []},
      extra_applications: [:logger, :runtime_tools]
    ]
  end

  def cli do
    [
      preferred_envs: [precommit: :test]
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
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.0"},

      # PubSub
      {:phoenix_pubsub, "~> 2.1"},

      # Phoenix / LiveView
      {:phoenix, "~> 1.8.3"},
      {:phoenix_html, "~> 4.1"},
      {:phoenix_live_reload, "~> 1.2", only: :dev},
      {:phoenix_live_view, "~> 1.1.0"},
      {:phoenix_live_dashboard, "~> 0.8.3"},
      {:esbuild, "~> 0.10", runtime: Mix.env() == :dev},
      {:tailwind, "~> 0.3", runtime: Mix.env() == :dev},
      {:heroicons,
       github: "tailwindlabs/heroicons",
       tag: "v2.2.0",
       sparse: "optimized",
       app: false,
       compile: false,
       depth: 1},
      {:swoosh, "~> 1.16"},
      {:gettext, "~> 1.0"},
      {:dns_cluster, "~> 0.2.0"},
      {:bandit, "~> 1.5"},

      # Boundary (compile-time architecture enforcement)
      {:boundary, "~> 0.10.4", runtime: false},

      # Dev / Test
      {:tidewave, "~> 0.5.5", only: :dev},
      {:lazy_html, ">= 0.1.0", only: :test},
      {:mox, "~> 1.0", only: :test},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:sobelow, "~> 0.14.1", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.40.1", only: :dev, runtime: false}
    ]
  end

  defp aliases do
    [
      setup: ["deps.get", "assets.setup", "assets.build"],
      "assets.setup": ["tailwind.install --if-missing", "esbuild.install --if-missing"],
      "assets.build": ["compile", "tailwind rlm", "esbuild rlm"],
      "assets.deploy": [
        "tailwind rlm --minify",
        "esbuild rlm --minify",
        "phx.digest"
      ],
      precommit: ["compile --warnings-as-errors", "deps.unlock --unused", "format", "test"]
    ]
  end

  defp docs do
    [
      main: "readme",
      extras: [
        "README.md": [title: "Overview"],
        "CHANGELOG.md": [title: "Changelog"]
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
          RLM.IEx
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
        ],
        "Web Dashboard": [
          RLMWeb,
          RLMWeb.Endpoint,
          RLMWeb.Router,
          RLMWeb.RunListLive,
          RLMWeb.RunDetailLive,
          RLMWeb.TraceComponents,
          RLMWeb.Telemetry
        ]
      ]
    ]
  end
end
