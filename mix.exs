defmodule Eai.MixProject do
  use Mix.Project

  def project do
    [
      app: :eai,
      version: "1.0.1",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      package: package(),
      docs: [extras: ["README.md"]]
    ]
  end

  def application do
    [
      extra_applications: [:logger, :crypto],
      mod: {Eai.Application, []}
    ]
  end

  defp deps do
    [
      # HTTP server (API endpoint)
      {:bandit, "~> 1.0"},

      # HTTP client
      {:req, "~> 0.5"},
      {:finch, "~> 0.19"},
      {:plug, "~> 1.16"},
      {:jason, "~> 1.4.5"},

      # PTY execution
      {:expty, "~> 0.2"},

      # Cache (optional, used by Eai.Task)
      {:nebulex, "~> 2.0"},
      {:shards, "~> 1.0"},

      # PubSub (used by Record)
      {:phoenix_pubsub, "~> 2.1"},

      # Development & testing
      {:dialyxir, "~> 1.4", only: [:dev], runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.31", only: [:dev], runtime: false},
      {:mix_test_watch, "~> 1.0", only: [:dev], runtime: false},
      {:benchee, "~> 1.0", only: [:dev], runtime: false}
    ]
  end

  defp package do
    [
      name: :eai,
      description:
        "Extreme minimal AI assistant with persistent PTY, recursive sub-agents, and CLI-based MCP/browser integration (mcporter, agent-browser)",
      files: [
        "lib",
        "priv",
        "mix.exs",
        "README.md",
        "LICENSE",
        # Base configs
        "config/config.exs",
        "config/dev.exs",
        "config/prod.exs",
        "config/runtime.exs",
        "config/test.exs",
        "config/cache.exs",
        # Hooks, prompts, tools — plugin architecture
        "config/hooks",
        "config/hooks/*.exs",
        "config/prompts",
        "config/prompts/*.exs",
        "config/tools",
        "config/tools/*.exs",
        # Public model configs (standard API endpoints)
        "config/models/claude_opus.exs",
        "config/models/claude_sonnet.exs",
        "config/models/deepseek.exs",
        "config/models/gpt4o.exs",
        "config/models/gpt4o_mini.exs",
        "config/models/llama3.exs",
        "config/models/llava.exs",
        # Character cards
        "config/chara_cards",
        "config/chara_cards/*.json"
      ],
      licenses: ["Apache-2.0"],
      links: %{"GitHub" => "https://github.com/TurinFohlen/eai"}
    ]
  end
end
