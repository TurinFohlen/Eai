defmodule Eai.MixProject do
  use Mix.Project

  def project do
    [
      app: :eai,
      version: "0.1.9",
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
      # HTTP client
      {:req, "~> 0.5"},
      {:finch, "~> 0.18"},
      {:jason, "~> 1.4.5"},

      # PTY execution
      {:expty, "~> 0.2"},

      # Cache (optional, used by Eai.Task)
      {:nebulex, "~> 2.0"},
      {:shards, "~> 1.0"},
      # Record
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
      description: "Extreme minimal AI assistant with persistent PTY and recursive sub-agents",
      files: [
        "lib",
        "priv",
        "config/**/*",
        "mix.exs",
        "README.md",
        "LICENSE"
      ],
      licenses: ["Apache-2.0"],
      links: %{"GitHub" => "https://github.com/TurinFohlen/eai"}
    ]
  end
end
