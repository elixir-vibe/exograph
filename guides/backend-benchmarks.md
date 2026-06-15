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

### MERGE fragment append

DuckDB docs and source notes indicate that recent `MERGE` paths can choose better bulk strategies than older `ON CONFLICT` index-conflict paths. After repeated parity benchmarks, Exograph uses the DuckDB MERGE fragment append path by default. The previous Ecto-style path remains available for comparison with:

```bash
mix exograph.index.hex --duckdb-fragment-append ecto ...
```

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

These early results made MERGE promising, but not yet sufficient to change the default. Later runs below resolved correctness blockers and provided the stronger evidence used to switch the DuckDB default to MERGE.

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

Post-dedupe repeated `top --limit 500 --concurrency 4` Ecto/MERGE pairs matched exactly for table counts and representative quality probes in clean runs:

| Run | Ecto wall / append | MERGE wall / append | Result |
|-----|--------------------:|---------------------:|--------|
| post-dedupe smoke | 129s / 117.3s | 120s / 93.7s | exact parity |
| decision run 1 | 132s / 117.5s | 122s / 96.1s | exact parity |
| decision run 4 | 132s / 115.2s | 153s / 123.2s | exact parity; MERGE wall-time outlier |
| decision run 5 | 132s / 109.7s | 131s / 101.0s | exact parity |
| decision run 6 | 129s / 117.6s | 123s / 99.9s | exact parity |

A clean `top --limit 2000 --concurrency 4` pair, after filling missing local tarballs, also matched exactly:

| Fragment append | Concurrency | Indexed | Skipped | Failed | Index elapsed | Wall time | `fragment_append_rows` total | Notes |
|-----------------|------------:|--------:|--------:|-------:|--------------:|----------:|-----------------------------:|-------|
| ecto + retry | 4 | 1635 | 365 | 0 | 9m00s | 569s | 652.9s | exact parity baseline |
| merge + retry | 4 | 1635 | 365 | 0 | 8m52s | 565s | 548.4s | exact parity; lower append time |

Based on the repeated exact-parity runs and the larger append-time reduction, DuckDB fragment append now defaults to MERGE while retaining `--duckdb-fragment-append ecto` as an escape hatch/comparison path.

Default-path validation after switching the default:

| Run | Indexed | Skipped | Failed | Index elapsed | Wall time | `duckdb_fragment_append` | `fragment_append_rows` total | Retry count | Notes |
|-----|--------:|--------:|-------:|--------------:|----------:|--------------------------|-----------------------------:|------------:|-------|
| `top --limit 500` | 379 | 121 | 0 | 1m58s | 130s | `merge` | 100.6s | 0 | default path, no explicit append flag |
| `top --limit 100 --reach` | 75 | 25 | 0 | 1m11s | 78s | `merge` | 21.6s | 0 | default path with Reach enabled |

A default `top --limit 2000` run also reported `duckdb_fragment_append: merge`, but the live top list had moved beyond the local tarball cache (`ash@3.29.0`, then `llm_db@2026.6.2`), so those runs are not clean quality/timing baselines. Use fixed entries or refresh the tarball cache before future top2000 default validation.

The benchmark workflow now supports entry snapshots with `--entries-output-path`, writing NDJSON lines like `{\"name\":\"jason\",\"version\":\"1.4.5\"}`. Rerun a fixed set with `--entries-file`. A fixed top2000 snapshot was created under ignored `bench-results/fixed-top2000-20260614/entries.ndjson`; after downloading the single missing tarball, the default MERGE run completed cleanly:

| Run | Indexed | Skipped | Failed | Index elapsed | Wall time | `duckdb_fragment_append` | `fragment_append_rows` total | Retry count | Notes |
|-----|--------:|--------:|-------:|--------------:|----------:|--------------------------|-----------------------------:|------------:|-------|
| fixed `top2000` entries | 1635 | 365 | 0 | 9m14s | 582s | `merge` | 596.1s | 1 | `--entries-file bench-results/fixed-top2000-20260614/entries.ndjson` |

A final fixed-snapshot comparison of explicit Ecto vs default MERGE matched exactly for table counts and representative probes:

| Fragment append | Indexed | Skipped | Failed | Index elapsed | Wall time | `fragment_append_rows` total | Retry count | Notes |
|-----------------|--------:|--------:|-------:|--------------:|----------:|-----------------------------:|------------:|-------|
| `ecto` | 1635 | 365 | 0 | 9m49s | 613s | 696.3s | 1 | explicit comparison path |
| default `merge` | 1635 | 365 | 0 | 9m13s | 579s | 580.4s | 0 | default path; exact parity with Ecto |

### Post-MERGE cost model

After making MERGE the default, `fragment_append_rows` is no longer the only story. Timing snapshots now include counter metrics for row volumes (`total`, `avg`, `max`) in addition to duration metrics (`total_ms`, `avg_ms`, `max_ms`). A fixed top500 default-MERGE run (`bench-results/stage-cost-20260615/top500-default-timings.json`) showed:

| Stage / metric | Value |
|----------------|------:|
| wall time | 135s |
| index elapsed | 123s |
| `index_sources` | 485.6s cumulative |
| `fragment_store_put` | 414.6s cumulative |
| `fragment_store_upsert_fragments` | 239.6s cumulative |
| `fragment_store_code_facts` | 122.5s cumulative |
| `fragment_store_resolve_fragment_ids` | 108.8s cumulative |
| `fragment_append_rows` | 105.6s cumulative |
| `fragment_store_normalize_terms` | 76.3s cumulative |
| `fragment_store_upsert_terms` | 52.8s cumulative |
| `code_facts_insert_comments` | 52.9s cumulative |
| input fragments | 985,339 rows |
| unique fragment rows | 976,408 rows |
| unique terms observed | 459,667 rows |
| reference facts | 739,115 rows |
| definition facts | 158,592 rows |
| comment facts | 21,064 rows |
| file rows | 3,714 rows |
| fragment append retries | 1 |

The next optimization target should be chosen from this profile rather than further MERGE tuning. The remaining storage-heavy cluster is fragment ID resolution + fact insertion + term normalization/upsert. Previous offline term-string batching and hybrid file handling both regressed, so prefer narrower, measurable changes such as reducing per-package ID lookup/fact flush overhead or improving fact/term batching without inflating staged payloads.

A follow-up split of `fragment_store_resolve_fragment_ids` showed that the fallback lookup is **not** the bottleneck in the default MERGE path (`bench-results/fragment-id-resolution-20260615/top500-default-timings.json`):

| Fragment ID resolution sub-stage / metric | Value |
|-------------------------------------------|------:|
| `fragment_store_resolve_fragment_ids` | 108.6s |
| `fragment_store_insert_fragments_by_hash` | 106.5s |
| `fragment_append_rows` | 105.4s |
| `fragment_store_missing_hashes` | 0.4s |
| `fragment_store_lookup_existing_fragment_ids` | 1.5s |
| unique fragment rows | 985,178 |
| inserted fragment rows returned | 982,754 |
| missing existing fragment IDs | 657 |

So optimizing the fallback `content_hash IN (...)` lookup is not worth pursuing now. The time attributed to ID resolution is almost entirely the MERGE append itself. Move the next optimization attempt to term/fact batching or broader flush granularity rather than fragment-ID lookup shape.

A follow-up fact-buffer split (`bench-results/fact-buffer-cost-20260615/top500-default-timings.json`) showed that code-fact insert time is mostly synchronous `InsertBuffer.insert/3` backpressure rather than final flush cost:

| Fact/buffer metric | Value |
|--------------------|------:|
| `fragment_store_code_facts` | 109.7s |
| `code_facts_insert_comments` | 41.4s |
| `code_facts_bulk_insert_comments` | 41.3s |
| `code_facts_insert_references` | 28.3s |
| `code_facts_bulk_insert_references` | 27.0s |
| `code_facts_insert_definitions` | 8.6s |
| `code_facts_bulk_insert_definitions` | 8.3s |
| `duckdb_insert_buffer_flush_references` | 26.0s across 14 flushes |
| `duckdb_insert_buffer_flush_definitions` | 5.6s across 4 flushes |
| `duckdb_insert_buffer_flush_comments` | 0.25s across 1 flush |
| reference rows enqueued/flushed | 732,375 / 750,994 |
| definition rows enqueued/flushed | 158,315 / 175,266 |
| comment rows enqueued/flushed | 20,283 / 26,131 |

The surprising comments cost is not comment row volume: comments flush only took ~0.25s. The expensive `code_facts_bulk_insert_comments` timing is the synchronous call into a shared InsertBuffer, which can block behind reference/definition flushes from other package tasks. The next low-risk experiment should therefore target InsertBuffer flush granularity/serialization (for example, larger per-source thresholds or per-source workers), not comment extraction or direct comment insert SQL.

Two immediate InsertBuffer variants did not justify a behavior change:

| Variant | Result |
|---------|--------|
| `--duckdb-insert-buffer-size 200000` | completed top500 but regressed wall time to 146s; fewer, larger flushes made final/large flushes expensive (`duckdb_insert_buffer_flush` 13.7s; definition flush 8.4s) and did not reduce comment enqueue backpressure enough |
| async flush prototype | not kept; naive `Task.async` from inside the GenServer let task replies hit `handle_info` before `Task.await`, causing final flush/reporting to hang |

A proper per-source worker version of the InsertBuffer did help. The public buffer API stayed the same, but each source table now has an independent worker, so comment enqueue calls no longer wait behind reference/definition flushes.

| Run | Indexed | Skipped | Failed | Index elapsed | Wall time | `fragment_store_code_facts` | `code_facts_bulk_insert_comments` | `fragment_append_rows` |
|-----|--------:|--------:|-------:|--------------:|----------:|----------------------------:|----------------------------------:|-----------------------:|
| fixed top500 baseline | 379 | 121 | 0 | 116.9s | ~124s | 109.7s | 41.3s | 105.4s |
| fixed top500 per-source workers | 379 | 121 | 0 | 97.6s | 106.7s | 72.8s | 0.05s | n/a in adjacent baseline |
| fixed top2000 default MERGE | 1635 | 365 | 0 | 553.3s | 579s | 537.1s | 233.8s | 580.4s |
| fixed top2000 per-source workers | 1635 | 365 | 0 | 470.9s | 495s | 459.6s | 7.9s | 435.7s |
| fixed top2000 per-source workers repeat | 1635 | 365 | 0 | 536.1s | 561s | 515.6s | 7.3s | 486.8s |

The top2000 runs used `bench-results/fixed-top2000-20260614/entries.ndjson`, completed with `1635 indexed / 365 skipped / 0 failed`, and still reported the default `duckdb_fragment_append: merge`. This is a real win, but it changes fact flushing from globally serialized to per-source serialized. Keep watching larger fixed-entry runs for DuckDB append contention and retry counts.

A follow-up split showed the remaining `code_facts_bulk_insert_references` time was mostly same-source worker queueing, not row construction. Switching worker enqueue from synchronous call to non-blocking cast keeps final `InsertBuffer.flush/1` as the durability barrier and moved that wait out of per-package indexing:

| Run | Indexed | Skipped | Failed | Index elapsed | Wall time | `fragment_store_code_facts` | `code_facts_bulk_insert_references` | reference worker service / flush |
|-----|--------:|--------:|-------:|--------------:|----------:|----------------------------:|------------------------------------:|--------------------------------:|
| fixed top500 non-blocking enqueue | 379 | 121 | 0 | 89.6s | 99.1s | 28.9s | 0.4s | 17.8s / 18.5s |
| fixed top2000 non-blocking enqueue | 1635 | 365 | 0 | 466.1s | 490s | 147.5s | 1.8s | 101.6s / 101.3s |

Fact row flush counts matched the prior per-source worker top2000 run (`references` 2,889,685; `definitions` 748,332; `comments` 113,887), so this change did not drop buffered facts in the fixed workload. A fresh fixed top2000 quality run also preserved indexed/skipped/failed totals and the same package/search/fact counts as the previous non-blocking summary, with only a 4-row `fragment_terms` difference out of ~99.4M rows; keep watching this tiny nondeterminism when changing fragment append concurrency.

The remaining wall time is now dominated by fragment append/upsert and the actual serialized DuckDB fact flushes rather than caller backpressure. A fixed top500 MERGE split (`bench-results/fragment-append-split-20260615/top500-split2-timings.json`) showed:

| MERGE append sub-stage | Total |
|------------------------|------:|
| `fragment_append_rows` / transaction | 92.3s / 92.2s |
| staging append into temp table | 32.5s |
| MERGE query | 27.6s |
| temp table create + clear | 1.4s |
| input / returned rows | 671,837 / 683,055 |

The temp-table DDL/cleanup is not the bottleneck. Increasing the fragment temp-stage append chunk size from 2k to 10k reduced fixed top500 `fragment_append_rows` from 92.3s to 80.5s and fixed top2000 elapsed to 460.4s (`1635 indexed / 365 skipped / 0 failed`). A 20k chunk was worse on fixed top500 (100.3s elapsed, 88.4s append), so 10k is the current local best.

A temporary cardinality probe showed the temp stage was already unique per call (`661,790` rows / `661,790` distinct hashes in the fixed top500 probe), and only `308` staged hashes already existed in the target at the sampled MERGE point. That does not support revisiting the earlier prelookup/minimal-key path: there are too few existing hashes to offset an extra lookup/staging pass. The probe was removed after recording the result because it added query overhead.

A local QuackDB prototype optimized ordinary signed 64-bit vector encoding, including large `BIGINT[]` child vectors. Dogfooding it through a temporary local path dependency produced a fixed top500 run with `379 indexed / 121 skipped / 0 failed`, `91.6s` elapsed, and `fragment_append_rows` at `78.8s` (`stage_rows` 28.7s, `merge_query` 20.0s). The change shipped in QuackDB `0.5.12`; after updating Exograph to the released dependency, fixed-snapshot runs completed cleanly:

| Run | Indexed | Skipped | Failed | Index elapsed | Wall time | `fragment_append_rows` | `stage_rows` | MERGE query |
|-----|--------:|--------:|-------:|--------------:|----------:|-----------------------:|-------------:|------------:|
| fixed top500, QuackDB `0.5.12` | 379 | 121 | 0 | 90.4s | 101.1s | 82.0s | 29.1s | 25.4s |
| fixed top2000, QuackDB `0.5.12` | 1635 | 365 | 0 | 465.1s | 489.4s | 522.6s | 92.5s | 213.7s |

A follow-up attempt to replace MERGE with `INSERT INTO ... SELECT ... WHERE NOT EXISTS ... RETURNING` using the same temp stage regressed fixed top500 (`114.2s` elapsed, `98.6s` append, `36.4s` stage append, `29.7s` insert query), so the MERGE shape remains better. The experiment was reverted.

QuackDB append telemetry is now captured in Hex timing snapshots when DuckDB indexing writes `--timings-path`. A fixed top500 telemetry run (`bench-results/quackdb-append-telemetry-20260615/top500-telemetry-timings.json`) showed the fragment temp-stage append payload is very wide:

| QuackDB append metric | Fragment temp stage |
|-----------------------|--------------------:|
| rows / batches | 671,837 / 3 |
| request bytes | 734.1 MB |
| encode duration | 10.6s |
| transport/server append duration | 3.5s transport / 14.3s append |
| surrounding `fragment_append_stage_rows` | 30.2s |

The gap between QuackDB append duration and `fragment_append_stage_rows` suggests Ecto adapter row normalization/DBConnection queue/transaction overhead is also material, not just protocol encoding. The next fragment-append work should target wide-row staging payload and adapter overhead before more SQL cleanup, prelookup, or anti-join insert-select tweaks.

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
