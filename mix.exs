defmodule Exograph.MixProject do
  use Mix.Project

  @version "0.8.0"
  @source_url "https://github.com/elixir-vibe/exograph"

  def project do
    [
      app: :exograph,
      version: @version,
      elixir: "~> 1.19",
      description:
        "Local CodeQL-style code search for Elixir, backed by DuckDB/QuackDB or Postgres and ExAST.",
      compilers: compilers(),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      docs: docs(),
      elixirc_paths: elixirc_paths(Mix.env()),
      aliases: aliases(),
      source_url: @source_url,
      homepage_url: @source_url,
      package: package()
    ]
  end

  def cli do
    [preferred_envs: [ci: :test]]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]

  defp deps do
    [
      {:ex_ast, "~> 0.11"},
      {:ex_dna, "~> 1.5"},
      {:ex_slop, "~> 0.4", only: [:dev, :test], runtime: false},
      {:reach, "~> 2.2", optional: true},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:broadway, "~> 1.2"},
      {:json_codec, "~> 0.1.1"},
      {:ecto_sql, "~> 3.13"},
      {:postgrex, "~> 0.22"},
      {:quackdb, "~> 0.5.3"},
      {:ex_doc, "~> 0.38", only: :dev, runtime: false},
      {:phoenix, "~> 1.8", optional: true},
      {:phoenix_html, "~> 4.1", optional: true},
      {:phoenix_live_view, "~> 1.1", optional: true},
      {:volt, "~> 0.11.1", optional: true},
      {:bandit, "~> 1.5", optional: true},
      {:hex_core, "~> 0.15", optional: true},
      {:req, "~> 0.5", optional: true},
      {:makeup, "~> 1.0", optional: true},
      {:makeup_elixir, "~> 1.0", optional: true},
      {:hammer, "~> 7.3", optional: true},
      {:dune, "~> 0.3", optional: true},
      {:phoenix_test, "~> 0.4", only: :test, runtime: false},
      {:phoenix_test_playwright, "~> 0.14", only: :test, runtime: false},
      {:phoenix_iconify, "~> 0.1", optional: true}
    ]
  end

  defp compilers do
    if Code.ensure_loaded?(PhoenixIconify.MixCompiler) do
      Mix.compilers() ++ [:phoenix_iconify]
    else
      Mix.compilers()
    end
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url},
      files: ~w(lib guides mix.exs README.md LICENSE CHANGELOG.md .formatter.exs)
    ]
  end

  defp docs do
    [
      main: "readme",
      source_ref: "v#{@version}",
      extras: [
        "CHANGELOG.md",
        "README.md",
        "guides/getting-started.md",
        "guides/querying.md",
        "guides/dsl.md",
        "guides/code-facts.md",
        "guides/call-graph.md",
        "guides/duckdb.md",
        "guides/postgres-paradedb.md",
        "guides/postgres-copy-staging.md",
        "guides/package-indexing.md",
        "guides/backend-benchmarks.md",
        "guides/mix-tasks.md",
        "guides/web-ui.md",
        "guides/api.md",
        "guides/comparisons.md",
        "guides/architecture.md"
      ]
    ]
  end

  defp aliases do
    [
      ci: [
        "compile --warnings-as-errors",
        "format --check-formatted",
        "volt.js.check",
        "test --include postgres",
        "cmd mix credo --strict",
        "cmd mix ex_dna",
        "cmd mix reach.check --smells --candidates"
      ]
    ]
  end
end
