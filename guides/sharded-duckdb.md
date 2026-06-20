# Sharded DuckDB semantics

Sharded DuckDB indexes split a corpus across multiple independent DuckDB databases and query them through `Exograph.ShardedIndex`. This is useful for large local corpora because it reduces single-file write/MERGE contention during ingestion.

Sharding is currently an opt-in architecture, not the default single-file DuckDB mode.

## CLI usage

Build a sharded Hex corpus by choosing a shard count, shard directory, and manifest path:

```bash
mix exograph.index.hex \
  --entries-file bench-results/fixed-top2000-20260614/entries.ndjson \
  --tarball-dir /tmp/exograph-top2000-tarballs \
  --concurrency 8 \
  --duckdb-shards 4 \
  --shard-concurrency 2 \
  --shard-pool-size 2 \
  --duckdb-threads 2 \
  --shard-dir data/hex-shards \
  --manifest-path data/hex-shards/manifest.term
```

Open a sharded corpus in the web UI with the manifest:

```bash
mix exograph.web \
  --manifest-path data/hex-shards/manifest.term \
  --duckdb-threads 2 \
  --shard-pool-size 1 \
  --shard-port-base 19700
```

The manifest stores shard file paths and package/version ownership metadata. Keep it with the shard database files; moving shard files requires updating or rebuilding the manifest.

## What is intended to match single-DB behavior

Package/version-scoped queries should route to the shard that owns the package version and should match the corresponding single-package results. Use package/version filters with the same identity stored in the manifest. Filters may be maps/keywords with `:name` and `:version`, or `Exograph.PackageVersion` structs with `:package_name` and `:version`:

```elixir
Exograph.search(index, "def handle_call(_, _, _) do ... end",
  package_version: %{name: "my_package", version: "1.2.3"}
)
```

The shard manifest records package/version ownership so `Exograph` can avoid querying unrelated shards.

## What is intentionally not transparent yet

Shard-local tables keep local fragment IDs, term IDs, and content de-duplication. As a result, global row counts and broad unscoped searches are not guaranteed to match a single logical DuckDB index.

Known differences from the fixed top500 probe:

- fragment/content/term de-duplication is shard-local;
- global `fragments`, `terms`, and `fragment_terms` counts can be higher than single-DB counts;
- broad structural queries can over-count;
- a simple fanout dedup by fragment hash did not restore parity.

Do not present sharded DuckDB as an invisible performance flag until global search semantics are redesigned.

## QuackDB boundary

Exograph owns sharded corpus semantics: package-to-shard ownership, shard-local versus global fragment identity, search fanout, ranking, and result aggregation. QuackDB should not grow generic application-level sharded search semantics at this stage.

If repeated infrastructure appears, only low-level primitives should move down to QuackDB later, such as managed server groups, connection-group lifecycle helpers, fanout execution helpers, or telemetry aggregation across connections.

## Product choices before making sharding default

A sharded read architecture needs explicit product semantics for global queries. Possible directions:

1. Keep shard-local identity and document global counts/search as shard-local aggregates.
2. Add a global result identity/ranking model for fanout search.
3. Use sharding only as a build/staging strategy, then finalize into one logical global index.

Until one of those is chosen, single-DuckDB online MERGE remains the default correctness baseline.
