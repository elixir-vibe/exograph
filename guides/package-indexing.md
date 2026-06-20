# Package Indexing

## Indexing Hex.pm

`mix exograph.index.hex` is the primary way to index Hex packages. DuckDB sharding is recommended for large local corpora.

    mix exograph.index.hex --mode latest --duckdb-shards 4 --duckdb-threads 1 --prefix hex

For a live dashboard during the run:

    mix exograph.index.hex --mode latest --concurrency 8 --web --port 4200

Open `http://localhost:4200/progress` to watch per-package status, rate, and ETA.

### Scale

On a full Hex.pm run with `--mode latest`:

| Metric | Value |
|--------|-------|
| Packages indexed | ~21k |
| Fragments | 13.8M |
| References | 35M |
| Database size | ~34 GB |

### Modes

| Mode | Description |
|------|-------------|
| `latest` | Most recent version of each package |
| `top --limit N` | Top N most-downloaded packages |
| `all` | Every published version |

### DuckDB sharding

With `--duckdb-shards N`, Exograph splits the package list across `N` independent DuckDB files. Indexing runs shard workers in parallel and returns a `%Exograph.ShardedIndex{}`. Query APIs fan out across shards and merge the global result limit.

Persist the shard manifest when you want to reopen the index later:

    mix exograph.index.hex \
      --mode latest \
      --duckdb-shards 4 \
      --duckdb-threads 1 \
      --manifest-path priv/exograph/hex.etf \
      --shard-dir priv/exograph/shards

Programmatic usage:

```elixir
result = Exograph.Hex.Corpus.index(
  repo: Exograph.DuckDBRepo,
  prefix: "hex",
  shards: 4,
  duckdb_threads: 1,
  manifest_path: "priv/exograph/hex.etf"
)

{:ok, hits} = Exograph.search_text(result.index, "defmodule", limit: 50)
```

Reopen the manifest in a fresh process:

```elixir
{:ok, index} = Exograph.open_sharded("priv/exograph/hex.etf", duckdb_threads: 1)
```

### Streaming pipeline

Each package follows: download tarball → extract source files → index → cleanup. Peak disk usage is proportional to active workers and shard count, not total corpus size. Non-Elixir packages (no `.ex` files) are detected and skipped.

### Resume behavior

Already-indexed packages (matched by name+version) are skipped automatically.
Use `--force` to re-index everything.

### Mirror balancing

Multiple `--mirror` flags distribute tarball downloads round-robin. By default, registry metadata is read from the first mirror so a self-hosted Hex-compatible mirror can be used without extra flags:

    mix exograph.index.hex \
      --mirror https://hex.elixir.toys \
      --concurrency 16

Use `--registry-url` when registry metadata and tarballs should come from different endpoints:

    mix exograph.index.hex \
      --registry-url https://hex.elixir.toys \
      --mirror https://hex.elixir.toys \
      --mirror https://repo.hex.pm \
      --concurrency 16

### Caching tarballs

Pass `--cache-tarballs DIR` to keep downloaded tarballs on disk. On subsequent
runs, already-cached tarballs are not re-downloaded.

    mix exograph.index.hex --cache-tarballs /data/hex-cache --mode latest

## Manual directory-based indexing

For non-Hex source archives or local package checkouts, use `Exograph.index/2`
directly:

```elixir
Exograph.index("sources/req_llm-1.11.0",
  repo: MyApp.Repo,
  migrate?: true,
  package_version: [
    ecosystem: :hex,
    name: "req_llm",
    version: "1.11.0",
    source_ref: "hex:req_llm:1.11.0"
  ]
)
```

Index multiple versions into the same prefix:

```elixir
for version <- ["1.11.0", "1.12.0"] do
  Exograph.index("sources/req_llm-#{version}",
    repo: MyApp.Repo,
    package_version: [ecosystem: :hex, name: "req_llm", version: version]
  )
end
```

Package and package-version records are normalized separately from files and
fragments, so re-indexing the same version is idempotent.

## Scoped queries

Restrict search to a specific package or version:

```elixir
Exograph.search(index, "Repo.get!(_, _)",
  package_id: pkg_id
)
```

The DSL and code-fact search APIs accept the same scope fields. The web UI shows
a package selector to scope the search without code changes.

## See also

- [Mix Tasks](mix-tasks.md) — full `mix exograph.index.hex` option reference
- [Web UI](web-ui.md) — progress dashboard
- [DuckDB and QuackDB](duckdb.md) — storage, sharding, manifests, tuning
