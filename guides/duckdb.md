# DuckDB and QuackDB

DuckDB is Exograph's storage engine. Exograph talks to DuckDB through [QuackDB](https://hex.pm/packages/quackdb), which gives Exograph an Ecto-compatible repo over the Quack protocol.

## Local DuckDB server

For a single DuckDB database, start a QuackDB server and point Exograph at it:

```elixir
{:ok, server} =
  QuackDB.Server.start_link(
    duckdb: :managed,
    database: "exograph.duckdb",
    token: "secret"
  )

Application.put_env(:my_app, MyApp.ExographRepo,
  uri: QuackDB.Server.uri(server),
  token: "secret",
  pool_size: 4
)
```

Then index with the QuackDB-backed repo:

```elixir
{:ok, index} =
  Exograph.index("lib",
    repo: MyApp.ExographRepo,
    prefix: "exograph",
    migrate?: true,
    duckdb_threads: 1
  )
```

`duckdb_threads: 1` is often fastest for package indexing because Exograph already parallelizes at the package/file level. For large analytical queries, a higher value can help.

## Sharded corpus indexing

For large Hex.pm indexes, prefer sharding:

```elixir
result =
  Exograph.Hex.Corpus.index(
    repo: Exograph.DuckDBRepo,
    prefix: "hex",
    mode: :latest,
    shards: 4,
    duckdb_threads: 1,
    manifest_path: "priv/exograph/hex.etf"
  )

index = result.index
```

Each shard is a separate DuckDB file and QuackDB server. Exograph indexes shards in parallel and returns `%Exograph.ShardedIndex{}`. Query APIs fan out across shards and merge the global top-k:

```elixir
{:ok, hits} = Exograph.search_text(index, "defmodule", limit: 50)
```

The manifest is an internal ETF file containing `%Exograph.DuckDBShards.Manifest{}` and `%Exograph.DuckDBShards.Shard{}` structs. Reopen it in a fresh process with:

```elixir
{:ok, index} = Exograph.open_sharded("priv/exograph/hex.etf", duckdb_threads: 1)
```

Do not run two QuackDB servers against the same DuckDB shard file at once; DuckDB correctly protects writable database files with locks. Corpus builds use DuckDB's normal WAL-backed persistence so completed shard manifests always reopen with durable data.

## CLI

```bash
mix exograph.index.hex \
  --mode latest \
  --duckdb-shards 4 \
  --duckdb-threads 1 \
  --manifest-path priv/exograph/hex.etf \
  --shard-dir priv/exograph/shards
```

For single-file DuckDB indexing, provide an existing QuackDB server with `--quackdb-uri` / `--quackdb-token` instead of `--duckdb-shards`.

## Resource utilization

Current indexing uses parallelism at several levels:

- package download/index workers (`--concurrency`)
- file parsing within each package (`:index_concurrency` internally)
- multiple DuckDB shards (`--duckdb-shards`)
- DuckDB execution threads per server (`--duckdb-threads`)

For the current workload, full CPU saturation is not guaranteed. After DuckDB append/staging optimizations, remaining wall time is often split across Hex download/cache, BEAM parsing, ExAST/Reach extraction, term normalization, and per-package orchestration. Too much DuckDB internal threading can oversubscribe the machine, so `--duckdb-threads 1` with several package/shard workers has benchmarked better than letting each DuckDB server use every core.

Good starting points:

```bash
# Smaller corpora / fewer cores
--duckdb-shards 4 --duckdb-threads 1 --concurrency 4

# Larger corpora / more cores
--duckdb-shards 8 --duckdb-threads 1 --concurrency 4
```

Then tune by watching CPU utilization and benchmark output. If CPU is underused, increase shards before increasing DuckDB threads. If run queue is high and latency gets worse, reduce DuckDB threads or package concurrency.
