# Backend benchmarks

These are local Exograph backend benchmarks for the Hex.pm `top` workload. They are intended to compare Exograph's current backend implementations on this machine, not to make a universal claim about PostgreSQL or DuckDB.

## Method

All runs used the same package cache and full Exograph persistence: files, fragments, ASTs, hashes, symbols, references, terms, and queryable facts were retained.

Common settings:

```bash
--mode top
--runs 3
--concurrency 4
--index-concurrency 4
--duckdb-threads 1
--postgres-defer-indexes
--postgres-synchronous-commit off
--postgres-maintenance-work-mem 512MB
--postgres-max-parallel-maintenance-workers 2
```

DuckDB sharded runs used:

```bash
--duckdb-shards 4 --duckdb-recovery-mode no_wal_writes
```

Postgres settings are a rebuildable/local-index challenge mode: deferred non-unique query indexes, `synchronous_commit=off`, and larger maintenance memory. They are not durable-production defaults.

## Indexing medians

| Workload | Postgres plain | DuckDB plain | DuckDB sharded plain | Result |
|----------|----------------|--------------|----------------------|--------|
| `top --limit 100` | 38.42s | 39.22s | 41.17s | tuned Postgres slightly faster |
| `top --limit 500` | 181.22s | 109.27s | 91.05s | DuckDB 1.66× faster; sharded DuckDB 1.99× faster |

For `limit 100`, the systems are close and tuned Postgres wins indexing. For `limit 500`, DuckDB wins indexing, and sharding improves throughput further.

## Query medians

### `top --limit 100`

| Query | Postgres plain | DuckDB plain | DuckDB sharded plain |
|-------|----------------|--------------|----------------------|
| `api_text_defmodule` | 71.1ms | 27.7ms | 45.4ms |
| `references_enum` | 24.1ms | 2.3ms | 3.3ms |
| `files_defmodule` | 31.0ms | 7.3ms | 2.4ms |
| `api_comments_todo` | 134.3ms | 129.8ms | 65.6ms |

### `top --limit 500`

| Query | Postgres plain | DuckDB plain | DuckDB sharded plain |
|-------|----------------|--------------|----------------------|
| `api_text_defmodule` | 134.2ms | 49.0ms | 37.0ms |
| `references_enum` | 56.7ms | 8.9ms | 9.9ms |
| `files_defmodule` | 98.3ms | 23.6ms | 7.1ms |
| `api_comments_todo` | 143.3ms | 159.1ms | 199.9ms |

Search/query paths usually favor DuckDB materially, especially on the larger workload.

## DuckDB Hex corpus notes, June 2026

A focused DuckDB Hex-corpus tuning pass used the local Hex tarball mirror and 16 DuckDB shards:

```bash
mix exograph.index.hex \
  --backend duckdb \
  --mode top \
  --limit 2000 \
  --concurrency 16 \
  --duckdb-shards 16 \
  --duckdb-threads 1 \
  --duckdb-recovery-mode no_wal_writes \
  --tarball-dir /srv/toys/hex-mirror/tarballs \
  --missing-tarballs-report-path /tmp/exograph-missing-top2000.json
```

The clean baseline after QuackDB `0.5.7` was later rechecked after QuackDB `0.5.8`'s DML-builder refactor. The `0.5.8` run used an equivalent temporary tarball mirror because `amqp@4.1.1` was missing from the shared mirror.

| QuackDB | Workload | Indexed | Skipped | Failed | Index elapsed | Wall time |
|---------|----------|--------:|--------:|-------:|--------------:|----------:|
| `0.5.7` | `top --limit 2000` | 1635 | 365 | 0 | 158.09s | 168.21s |
| `0.5.8` | `top --limit 2000` | 1635 | 365 | 0 | 156.99s | 166.86s |

No missing local tarballs were reported for either completed run. The largest cumulative timing buckets in the `0.5.7` baseline were:

| Stage | Total |
|-------|------:|
| `fragment_store_put` | 1094.4s |
| `fragment_store_upsert_fragments` | 555.0s |
| `fragment_store_code_facts` | 433.2s |
| `fragment_store_resolve_fragment_ids` | 237.1s |
| `fragment_append_rows` | 230.7s |
| `code_facts_insert_references` | 179.5s |
| `fragment_store_build_fragment_rows` | 160.6s |
| `fragment_store_normalize_terms` | 150.9s |

QuackDB `0.5.6` and `0.5.7` included small adapter/protocol improvements for Ecto native append paths. QuackDB `0.5.8` reused QuackDB's DML builder for the same Ecto append temporary-table SQL and was performance-neutral in the full workload. These changes were positive or neutral but not large enough to change the main bottleneck: fragment append/upsert remains dominated by the append + conflict-ignore + returning/staging path.

### Experimental MERGE fragment append

DuckDB docs and source notes indicate that recent `MERGE` paths can choose better bulk strategies than older `ON CONFLICT` index-conflict paths. Exograph therefore has an experimental DuckDB fragment append path enabled with:

```bash
mix exograph.index.hex --duckdb-fragment-append merge ...
```

This keeps the default Ecto `insert_all(..., insert_method: :append, on_conflict: :nothing, returning: ...)` path unchanged unless explicitly requested.

Initial `top --limit 2000` results:

| Mode | Indexed | Skipped | Failed | Index elapsed | Wall time | `fragment_append_rows` total |
|------|--------:|--------:|-------:|--------------:|----------:|-----------------------------:|
| default (`0.5.8`) | 1635 | 365 | 0 | 156.99s | 166.86s | 241.2s |
| `--duckdb-fragment-append merge` run 1 | 1635 | 365 | 0 | 153.91s | 158.99s | 188.0s |
| `--duckdb-fragment-append merge` run 2 | 1635 | 365 | 0 | 157.16s | 166.95s | 186.1s |

A persisted `top --limit 500` quality check matched the default path:

| Query/check | Default | MERGE |
|-------------|--------:|------:|
| `Map.get(_, _)` | 7 | 7 |
| `Enum.map(_, _)` | 959 | 959 |
| `_ |> _` | 1864 | 1864 |
| `jason` fragments | 1391 | 1391 |

This is promising but still experimental. `fragment_append_rows` consistently improved, but end-to-end wall time remained noisy; do not make it the default until more repeated full-workload runs show a stable total-time win.

A later single-DB `top --limit 500` comparison with local tarballs still did not justify changing the default:

| Fragment append | Indexed | Skipped | Failed | Index elapsed | Wall time | `fragment_append_rows` total | Notes |
|-----------------|--------:|--------:|-------:|--------------:|----------:|-----------------------------:|-------|
| ecto | 379 | 121 | 0 | 1m42s | 112s | 97.3s | baseline |
| merge | 379 | 121 | 0 | 1m41s | 111s | 96.2s | representative structural/text/package checks matched, but fact table counts differed (`definitions` +140, `references` +762, `comments` +4) and need investigation before further promotion |

A follow-up investigation found two correctness issues around this comparison rather than a proven MERGE quality regression:

- File lookup after file upserts must be scoped by `{package_version_id, sha256}`, not only by SHA, because different package versions can legitimately share identical files.
- `duckdb_fragment_append` was recorded in Hex index reports but was not forwarded from `Exograph.Hex.Corpus` into per-package `Exograph.index_sources/2` calls, so earlier corpus-level MERGE comparisons were not a clean test of the MERGE path.

A focused `mariaex@0.9.1` rerun after forwarding the option showed Ecto and MERGE fact counts match exactly (`fragments` 4614, `definitions` 1043, `references` 5307, `comments` 59). This restores confidence in MERGE correctness for the known repro, but the previous top500 MERGE numbers should be treated as invalidated.

Clean follow-up artifacts live under ignored `bench-results/duckdb-merge-20260614/`; large `.duckdb` files were removed after comparison. With `--concurrency 4`, the Ecto baseline hit a DuckDB unique-constraint race in the append path while indexing `cachex@4.1.1`, so that run is not a valid quality baseline. MERGE completed the same workload successfully:

| Fragment append | Concurrency | Indexed | Skipped | Failed | Index elapsed | Wall time | `fragment_append_rows` total | Notes |
|-----------------|------------:|--------:|--------:|-------:|--------------:|----------:|-----------------------------:|-------|
| ecto | 4 | 378 | 121 | 1 | 1m53s | 125s | 111.3s | failed on duplicate `content_hash` unique constraint while indexing `cachex@4.1.1` |
| merge | 4 | 379 | 121 | 0 | 1m50s | 122s | 93.3s | completed; not directly comparable because Ecto failed |

DuckDB source inspection explains the failure shape: `PhysicalInsert::OnConflictHandling` verifies conflicts before append, then concurrent transactions can still both try the same unique ART key and one fails at commit. The relevant source paths are `src/execution/operator/persistent/physical_insert.cpp`, `src/common/types/conflict_manager.cpp`, and `src/execution/index/art/art.cpp`. Exograph now retries DuckDB fragment appends on primary-key/unique-constraint races inside the fragment append operation, allowing the losing transaction to re-run after the winner commits.

After that retry guard, the same `top --limit 500 --concurrency 4` Ecto workload completed:

| Fragment append | Concurrency | Indexed | Skipped | Failed | Index elapsed | Wall time | `fragment_append_rows` total | Notes |
|-----------------|------------:|--------:|--------:|-------:|--------------:|----------:|-----------------------------:|-------|
| ecto + retry | 4 | 379 | 121 | 0 | 1m54s | 124s | 118.1s | clean completion after unique-conflict retry |

Repeated `top --limit 500 --concurrency 4` Ecto/MERGE pairs still do **not** justify making MERGE the default. Artifacts live under ignored `bench-results/duckdb-merge-repeat-20260614/`; large `.duckdb` files were removed after each comparison.

| Run | Ecto result | MERGE result | Wall time Ecto/MERGE | `fragment_append_rows` Ecto/MERGE | Quality/count parity | Notes |
|-----|-------------|--------------|----------------------:|----------------------------------:|----------------------|-------|
| 1 | 379 indexed, 0 failed | 378 indexed, 1 failed | 127s / 123s | 119.1s / 102.4s | no | MERGE hit the same DuckDB unique-constraint commit race before broadening the retry guard |
| 2 | 379 indexed, 0 failed | 379 indexed, 0 failed | 130s / 122s | 120.7s / 97.0s | yes | clean MERGE win |
| 3 | 379 indexed, 0 failed | 379 indexed, 0 failed | 126s / 121s | 120.0s / 97.6s | no | representative searches matched, but fact counts differed (`definitions` +238, `references` +1227, `comments` +14) |
| 4 | not rerun | 379 indexed, 0 failed | n/a / 125s | n/a / not summarized here | n/a | after broad retry, MERGE completed but produced the lower fact-count variant (`definitions` 175434, `references` 751847, `comments` 26135) |

The concurrency-4 fact-count nondeterminism was traced to duplicate source paths inside Hex tarballs rather than MERGE itself. `mariaex@0.9.1` contains repeated identical entries for paths such as `lib/mariaex/protocol.ex` and `lib/mariaex/row_parser.ex`. Exograph now deduplicates source tuples by `{path, package_version}` before extraction, so duplicate archive entries do not insert duplicate definitions/references/comments.

A focused `mariaex@0.9.1` rerun after source dedupe matched Ecto and MERGE exactly with the lower, deduplicated fact counts (`fragments` 4614, `definitions` 665, `references` 3318, `comments` 41).

A post-dedupe `top --limit 500 --concurrency 4` Ecto/MERGE pair matched exactly for table counts and representative quality probes:

| Fragment append | Concurrency | Indexed | Skipped | Failed | Index elapsed | Wall time | `fragment_append_rows` total | Notes |
|-----------------|------------:|--------:|--------:|-------:|--------------:|----------:|-----------------------------:|-------|
| ecto + retry | 4 | 379 | 121 | 0 | 1m59s | 129s | 117.3s | deduped sources |
| merge + retry | 4 | 379 | 121 | 0 | 1m49s | 120s | 93.7s | exact parity with Ecto for files, fragments, terms, fragment_terms, definitions, references, comments, searches, and package checks |

A serial `top --limit 500 --concurrency 1` run remains the earlier clean correctness comparison. Counts and representative checks matched exactly for files, fragments, terms, fragment_terms, definitions, references, comments, packages, package_versions, `defmodule`, `Map.get(_, _)`, `Enum.map(_, _)`, `_ |> _`, and package fragment counts for `jason`, `ecto`, and `phoenix`:

| Fragment append | Concurrency | Indexed | Skipped | Failed | Index elapsed | Wall time | `fragment_append_rows` total | Notes |
|-----------------|------------:|--------:|--------:|-------:|--------------:|----------:|-----------------------------:|-------|
| ecto | 1 | 379 | 121 | 0 | 5m04s | 315s | 86.8s | clean baseline |
| merge | 1 | 379 | 121 | 0 | 4m44s | 296s | 73.3s | exact quality/count parity; ~19s wall improvement in this serial run |

Historical invalidated artifacts: `/tmp/exograph-top500-ecto-report.json`, `/tmp/exograph-top500-ecto-timings.json`, `/tmp/exograph-top500-merge-report.json`, `/tmp/exograph-top500-merge-timings.json`.

Reports include selected DuckDB experiment metadata under `options`, including `duckdb_fragment_append` and `duckdb_build_mode`. The `--duckdb-build-mode offline` flag selects the experimental offline staging path for files, terms, fragments, definitions, references, comments, fragment_terms, graph_nodes, and call_edges. Keep it explicit until quality parity and larger repeated benchmarks are complete.

Automated top-package parity guards now compare online vs offline counts for files, fragments, terms, fragment_terms, definitions, references, comments, graph_nodes, call_edges, and representative text/definition/reference/caller/callee searches.

Initial `top --limit 100` sharded smoke, using local tarballs and `--duckdb-shards 2`, showed quality-level totals match but no end-to-end win yet:

| Build mode | Indexed | Skipped | Failed | Index elapsed | Wall time | Notes |
|------------|--------:|--------:|-------:|--------------:|----------:|-------|
| online | 75 | 25 | 0 | 50.54s | 52s | baseline online path |
| offline | 75 | 25 | 0 | 50.48s | 52s | stages files/terms/fragments/facts, but still finalizes files/terms during per-package puts |

This supports the next milestone: batch staging across larger units and finalize once per shard/corpus, rather than repeatedly resolving file/term IDs during `FragmentStore.put/2`.

Initial single-DB `top --limit 100 --reach` smoke results:

| Build mode | Indexed | Skipped | Failed | Index elapsed | Wall time | Notes |
|------------|--------:|--------:|-------:|--------------:|----------:|-------|
| online + Reach | 75 | 25 | 0 | 64.35s | 69s | baseline online Reach path |
| offline + Reach | 75 | 25 | 0 | 61.87s | 73s | stages call graph facts; slower wall due finalization/staging overhead |

A sharded online + Reach top100 run exposed a dynamic-repo issue in asynchronous call-graph inserts (`could not lookup Ecto repo Exograph.DuckDBRepo`). `Exograph.Storage.Ecto.SQL.bulk_insert_all/4` now preserves the current dynamic repo in async chunk insert tasks; sharded online + Reach top10 and top100 runs completed successfully after the fix.

Sharded `top --limit 100 --reach`, using local tarballs and `--duckdb-shards 2` after the dynamic-repo fix:

| Build mode | Indexed | Skipped | Failed | Index elapsed | Wall time | Notes |
|------------|--------:|--------:|-------:|--------------:|----------:|-------|
| online + Reach | 75 | 25 | 0 | 65.46s | 67s | sharded baseline after dynamic-repo fix |
| offline + Reach | 75 | 25 | 0 | 61.51s | 63s | stages call graph facts; still pays larger finalization cost |

### Package batching experiment

`mix exograph.index.hex` has an explicit `--package-batch-size` option for experimenting with flushing multiple packages together. Quality checks on `top --limit 500` matched the default mode for representative structural queries:

| Query/check | Default | Batch size 4 |
|-------------|--------:|-------------:|
| `Map.get(_, _)` | 7 | 7 |
| `Enum.map(_, _)` | 959 | 959 |
| `_ |> _` | 1864 | 1864 |
| `jason` fragments | 1391 | 1391 |

Controlled `top --limit 1000` benchmarks with 16 shards were noisy and did not justify changing the default:

| `--package-batch-size` | Run 1 | Run 2 | Median |
|-----------------------:|------:|------:|-------:|
| 1 | 134.5s | 116.8s | 125.6s |
| 2 | 145.7s | 150.1s | 147.9s |
| 4 | 126.2s | 130.3s | 128.2s |

Keep package batching explicit until a larger corpus or repeated low-noise runs show a consistent win.

### Dead ends from the tuning pass

The following experiments were reverted because they were neutral or worse on the full workload, even when some looked promising in microbenchmarks:

- Prelooking up existing fragment hashes and direct-appending only missing rows.
- Replacing the Ecto append/conflict path with an Exograph-local temp staging table plus `INSERT ... SELECT ... WHERE NOT EXISTS`; a `top --limit 500` run was slower than the default path (`1m12s` vs `1m05s` index elapsed in adjacent runs).
- Resolving existing fragment IDs through a DuckDB temp hash table and join. Isolated lookups were faster for large hash sets, but full `top --limit 2000` indexing regressed (`2m43s` index elapsed vs `2m37s` for the adjacent `0.5.8` baseline), likely because transaction/temp-table overhead outweighed lookup gains in the real workload.
- Batch-staging term strings in offline mode and resolving `fragment_terms` at finalization time. Top-package parity passed, but `top --limit 100` single-DB indexing regressed badly: online was `75 indexed / 25 skipped / 0 failed`, `53s` index elapsed and `60s` wall including a compile; the experimental offline term-batched path was `75 indexed / 25 skipped / 0 failed`, `1m07s` index elapsed and `75s` wall. Timings showed `offline_build_stage_fragments` ballooning to `124.2s` total, so staging large per-fragment term-string payloads was worse than resolving term IDs during per-package puts. Artifacts: `/tmp/exograph-batch-online-top100-report.json`, `/tmp/exograph-batch-online-top100-timings.json`, `/tmp/exograph-batch-offline-top100-report.json`, `/tmp/exograph-batch-offline-top100-timings.json`.
- Hybrid offline mode that used the normal online file upsert path while keeping offline fragment/fact staging. Top-package parity passed, but `top --limit 100` remained slower than online: adjacent online was `75 indexed / 25 skipped / 0 failed`, `55s` index elapsed and `62s` wall; hybrid offline was `75 indexed / 25 skipped / 0 failed`, `1m04s` index elapsed and `73s` wall. Artifacts: `/tmp/exograph-hybrid-online-top100-report.json`, `/tmp/exograph-hybrid-online-top100-timings.json`, `/tmp/exograph-hybrid-offline-top100-report.json`, `/tmp/exograph-hybrid-offline-top100-timings.json`.
- Removing post-insert temp-table cleanup.
- Combining temp-table create and clear statements.
- Switching temp-table cleanup from `DELETE` to `TRUNCATE`.
- Increasing DuckDB code-fact insert buffer size from 50k to 100k.
- Changing AST compression level or selectively changing fragment row construction.
- Fusing code-fact extraction passes.
- Special-casing int64, blob, or LIST vector encoding in QuackDB without full-workload wins.
- Lowering per-package source parsing concurrency.

The next meaningful design target is a dedicated bulk fragment upsert/staging path below the current SQL/Ecto shape. A local SQL staging rewrite was not enough; the larger design likely needs adapter-level support that reduces append + conflict-ignore + ID lookup work together rather than rearranging the same operations.

## Artifacts

Machine-readable benchmark artifacts are generated locally and intentionally not committed to git. Use `--output-json` for the JSON report and `--explain-dir` for Postgres plans, for example:

```bash
mix exograph.bench.backends \
  --mode top --limit 500 --runs 3 \
  --only postgres_plain,duckdb_plain,duckdb_sharded_plain \
  --output-json bench-results/backend-limit500-runs3-current.json \
  --explain-dir bench-results/explain-limit500-runs3-current
```

`bench-results/` is gitignored to avoid polluting the repository with local benchmark outputs. The tables above record the latest checked benchmark summary; regenerate artifacts locally when you need machine-readable evidence or plans.

## Current fair wording

A defensible summary is:

> On Exograph's Hex.pm top-package workload, tuned Postgres is slightly faster at indexing 100 packages. At 500 packages, DuckDB indexes about 1.66× faster single-node and about 1.99× faster with 4 shards, while several important query paths are roughly 3×–14× faster on DuckDB. These numbers describe Exograph's current backends and local benchmark setup, not PostgreSQL or DuckDB universally.
