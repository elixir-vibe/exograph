# Getting Started

## Installation

Add Exograph to your deps:

```elixir
def deps do
  [
    {:exograph, "~> 0.7"}
  ]
end
```

DuckDB through QuackDB is Exograph's storage engine.

The Mix tasks start a managed QuackDB server automatically when `--quackdb-uri` is omitted. Use `--duckdb-database` to choose the DuckDB file path. For large Hex.pm corpora, prefer the sharded DuckDB mode shown below, which starts managed shard servers for you.

## Index your project

Point Exograph at your source directories with `--migrate` to create the tables:

    mix exograph.index --migrate lib

To also index tests and set a custom prefix:

    mix exograph.index --migrate --prefix exograph lib test

From Elixir:

```elixir
{:ok, index} =
  Exograph.index("lib",
    repo: MyApp.Repo,
    prefix: "exograph",
    migrate?: true
  )
```

`migrate?: true` runs Exograph's Ecto migrations under the configured prefix.
Re-running is safe; migrations are idempotent.

## Search from CLI

Structural search — finds fragments matching an ExAST pattern:

    mix exograph.search 'Repo.get!(_, _)' --migrate lib

Text search:

    mix exograph.search 'TODO' --text --migrate lib

Regex search:

    mix exograph.search 'Repo\.get!\(' --regex --migrate lib

Structural search with predicates:

    mix exograph.search 'def _ do ... end' \
      --migrate lib \
      --contains 'Repo.transaction(_)' \
      --not-contains 'IO.inspect(_)'

## Start the web UI

    mix exograph.web --prefix exograph --port 4200

Open `http://localhost:4200`. The editor supports structural, text, and regex modes.

## Index Hex.pm packages

Download and index packages straight from Hex.pm with sharded DuckDB:

    mix exograph.index.hex \
      --mode top --limit 1000 \
      --duckdb-shards 4 \
      --duckdb-threads 1 \
      --manifest-path priv/exograph/hex.etf

This streams package sources into independent DuckDB shard files. Already-indexed packages are skipped automatically inside each shard.

Watch progress live by adding `--web`:

    mix exograph.index.hex --mode latest --concurrency 8 --web --port 4200

The dashboard at `http://localhost:4200/progress` shows per-package status,
rate, and ETA.

Modes:
- `latest` — most recent version of each package (default)
- `top --limit N` — top N most-downloaded packages
- `all` — every published version

See [Package Indexing](package-indexing.md) for scale numbers and full options.

## Next steps

- [Querying](querying.md) — structural patterns, text/regex search, planning
- [DSL](dsl.md) — join code facts with structural predicates
- [Mix Tasks](mix-tasks.md) — all CLI options
- [DuckDB and QuackDB](duckdb.md) — storage, sharding, manifests, tuning
