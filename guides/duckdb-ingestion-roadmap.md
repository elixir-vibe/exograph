# DuckDB ingestion roadmap

This note tracks longer-horizon ideas for Exograph's DuckDB Hex-corpus builder. The goal is to preserve search quality while reducing the current append/upsert/ID-resolution bottlenecks.

## Current state

The default DuckDB path uses normal Ecto semantics:

```elixir
Repo.insert_all(FragmentRecord, rows,
  insert_method: :append,
  on_conflict: :nothing,
  conflict_target: [:content_hash],
  returning: [:id, :content_hash]
)
```

This path remains available behind `--duckdb-fragment-append ecto`, but it pays DuckDB unique/ART index maintenance and conflict checking during online ingestion.

DuckDB fragment append now defaults to the MERGE path after repeated parity benchmarks. The previous Ecto-style append path can be forced with:

```bash
mix exograph.index.hex --duckdb-fragment-append ecto ...
```

There is also an experimental DuckDB build-mode option for report/benchmark labeling:

```bash
mix exograph.index.hex --duckdb-build-mode offline ...
```

The build-mode flag now selects an initial offline staging path for files, terms, fragments, definitions, references, comments, and fragment_terms. The default remains online, and the offline path is still experimental until quality parity and larger benchmarks are complete. For reproducible topN runs, write the resolved package list with `--entries-output-path` and rerun with `--entries-file` instead of relying on a live top list.

MERGE measurements show lower cumulative `fragment_append_rows` time, exact `top --limit 500 --concurrency 1` parity, repeated exact post-dedupe `top --limit 500 --concurrency 4` parity, and exact fixed-snapshot `top2000 --concurrency 4` parity against explicit Ecto. The default path was then validated on `top --limit 500`, `top --limit 100 --reach`, and fixed top2000 entries; all reported `duckdb_fragment_append: merge` without requiring the explicit flag. A `top --limit 500 --concurrency 4` Ecto baseline failed once on a DuckDB duplicate unique-key race while the MERGE run completed. DuckDB source inspection shows `ON CONFLICT` conflict handling is scoped to the current insert chunk/visible rows before append; concurrent transactions can still both attempt the same unique ART key and one can fail at commit. Exograph now retries DuckDB fragment appends on primary-key/unique-constraint races inside the fragment append operation and records `fragment_append_retries` in timing snapshots. The later fact-count nondeterminism was traced to duplicate source paths inside Hex tarballs; Exograph now deduplicates source tuples by `{path, package_version}` before extraction.

## QuackDB DSL requirement

Do not grow more hand-rolled MERGE SQL in Exograph. QuackDB now has a DML helper for this shape:

```elixir
QuackDB.DML.merge_into("fragments",
  using: "fragment_stage",
  target_as: :target,
  source_as: :source,
  on: [:content_hash],
  when_not_matched: {:insert, columns},
  returning: [:content_hash, :id]
)
```

Future Exograph MERGE code should use this or a similarly named higher-level helper, not local string assembly.

## Roadmap

1. **Watch the MERGE default on larger workloads**
   - Keep `--duckdb-fragment-append ecto` as the comparison/escape path.
   - Repeat top2000/top5000 runs with fixed entries or a refreshed tarball cache when changing ingestion internals.
   - Track whether the DuckDB fragment append retry fires often enough to affect throughput.
   - Use timing counter metrics for row volumes before choosing the next batching target.
   - Keep quality checks as benchmark assertions:
     - `Map.get(_, _)`
     - `Enum.map(_, _)`
     - `_ |> _`
     - package fragment counts such as `jason`.

2. **Increase ingestion flush granularity**
   - The post-MERGE cost model points at fact insertion and term normalization/upsert as the next likely targets; fragment ID resolution was split and proved to be almost entirely MERGE append time, with fallback existing-ID lookup only ~1.5s in a fixed top500 run.
   - Fact insertion timing was largely synchronous InsertBuffer backpressure: comment row volume is small, but comment enqueue calls waited behind reference/definition buffer flushes on the shared GenServer.
   - A larger shared buffer threshold (`200000`) and a naive async flush prototype did not help.
   - Per-source InsertBuffer workers did help: fixed top500 index elapsed improved from 116.9s to 97.6s, and fixed top2000 improved from 553.3s to 470.9s in the first run while preserving `1635 indexed / 365 skipped / 0 failed`; a repeat was noisier at 536.1s but still completed cleanly.
   - Non-blocking enqueue into those per-source workers moved same-source worker queueing out of per-package indexing: fixed top500 improved to 89.6s elapsed and fixed top2000 completed at 466.1s with matching flushed fact row counts. Final `InsertBuffer.flush/1` is now the durability barrier for buffered DuckDB facts.
   - Continue watching memory, DuckDB append contention, retry counts, and tiny `fragment_terms` nondeterminism because fact flushes are now per-source serialized and enqueue no longer provides as much producer backpressure.
   - Fragment append sub-stage instrumentation now splits temp-stage creation/clearing, temp-stage append, MERGE query, transaction, attempts, input rows, and returned rows. Fixed top500 showed temp-table DDL/cleanup is negligible (~1.4s) while staging append (~32.5s) and MERGE query (~27.6s) dominate inside the ~92s transaction. Raising temp-stage append chunking from 2k to 10k helped; 20k regressed on fixed top500, so keep 10k unless a larger repeated run says otherwise.
   - A temporary cardinality probe showed the temp stage was already unique per call and had very few already-existing target hashes (`308` in the fixed top500 probe), so do not revive the earlier prelookup/minimal-key path without new evidence.
   - Replacing MERGE with `INSERT INTO ... SELECT ... WHERE NOT EXISTS ... RETURNING` over the same temp stage regressed fixed top500, so keep MERGE for now.
   - QuackDB append telemetry is now included in Hex timing snapshots when `--timings-path` is used. Fixed top500 showed the fragment temp-stage append sends ~734 MB for ~672k rows, with ~10.6s encode time and ~14.3s total append duration inside a ~30.2s `fragment_append_stage_rows` call; adapter/queue/transaction overhead around native append is therefore also material.
   - Direct append variants were investigated and reverted. Repo-pool direct append cannot see transaction-local temp tables; active-transaction direct append works only via Ecto internals and regressed top500; unique persistent staging tables also regressed due create/drop and cross-connection append cost. Do not pursue active-transaction append or non-temp staging further unless a QuackDB-side helper plus fresh benchmark changes the result.
   - Per-column payload attribution (`--duckdb-fragment-payload-metrics`) showed the fragment staging request is dominated by `ast` (~452.6 MB), `terms` (~234.1 MB), and `sub_hashes` (~56.4 MB) in fixed top500. A two-phase narrow-key/direct-insert prototype reduced append request bytes but regressed top500 (`111.3s` elapsed, `103.8s` append; direct insert `59.8s`) and was reverted.
   - Fetch telemetry plus an offline DuckDB CLI MERGE profile showed MERGE `RETURNING` result fetch is small (~0.55s), while a comparable CLI MERGE-with-RETURNING operator profile was only ~3.5s latency / ~2.6s CPU.
   - Local QuackDB query-phase telemetry dogfood split query/fetch encode, transport, decode, normalize, and bytes. Fixed top500 showed aggregated `INSERT` query time is almost entirely transport/server execution (`63.0s` query duration, `62.8s` transport) while fetch/materialization is small (`0.43s`, `5.2 MB`). These metrics shipped in QuackDB 0.5.13; the released top500 smoke completed in ~91.7s with ~87.2s fragment append, ~27.9s stage append, and ~25.9s MERGE query. A synthetic QuackDB wide-append matrix for the fragment-stage payload shape (`670k` rows / `721 MB`) showed concurrency improves wall time but inflates aggregate transport/server cost (`1x10k`: ~12.66s wall / ~11.66s append; `4x10k`: ~7.56s wall / ~27.91s append). Larger chunks reduced isolated benchmark overhead (`4x40k`: ~5.33s wall / ~18.87s append), but Exograph fixed-top500 with `40k` stage chunks did not improve the full workload (~92.2s elapsed, ~86.6s fragment append, ~27.9s stage append, ~25.3s MERGE query). Keep the production stage chunk at `10k`; simple chunk tuning is exhausted. The remaining app-side gaps likely sit in DuckDB/Quack server contention under concurrent native append and server-side MERGE execution/storage/checkpoint behavior rather than client-side query row materialization.
   - DuckDB's built-in structured `Quack` logs were investigated and reverted as an Exograph hook: small probes produced empty `duckdb_logs`/`duckdb_logs_parsed('Quack')`, and enabling `CALL enable_logging(['Quack'])` before fixed top500 caused early package timeouts. Do not rely on built-in Quack logs for this workload without upstream changes.
   - DuckDB CLI profiling of a wide temp-stage/MERGE reproduction over the same fixed top500 database showed stage CTAS at ~0.25s latency and MERGE-with-RETURNING at ~3.29s latency / ~2.26s CPU, versus app-side `fragment_append_merge_query` around ~22.1s. This points away from the core DuckDB MERGE operator and toward Quack server request handling/serialization, remote temp-stage append ingestion, transaction/commit scheduling, or connection contention.
   - A local query-telemetry run with `--concurrency 1` reduced MERGE query time from ~27.1s to ~8.3s and `INSERT` query transport from ~62.8s to ~24.3s, but regressed wall time to ~251s by serializing extraction/indexing.
   - A coarse fragment-append semaphore prototype with package concurrency still at 4 also regressed and was reverted. Limit 1 reduced MERGE query to ~14.3s but added ~74.8s limiter wait (`114.1s` elapsed); limit 2 regressed to ~101.0s elapsed and did not improve MERGE. Do not pursue transaction-level fragment append semaphores. Future concurrency work needs narrower critical sections or a real pipelined writer/ingestion design.
   - A four-shard DuckDB ingestion probe improved fixed-top500 wall time only when global concurrency increased to 8 and per-shard concurrency/pool size to 2 (`70.2s` vs single-DB concurrency-8 `76.3s`, and normal concurrency-4 baseline `91.7s`). It confirmed single-file MERGE/write contention matters (`12.0s` aggregate MERGE vs single-DB concurrency-8 `33.1s`), but it is not correctness-equivalent: content/term de-duplication is shard-local, increasing fragment/term counts and over-counting at least one broad structural query. A simple fanout result dedup by fragment hash was tested and reverted because it did not fix the structural over-count and regressed other counts. Treat sharding as a possible read-shard/product architecture only with redesigned global de-dup/search semantics, not a drop-in ingestion optimization.
   - An offline deferred-term prototype improved offline top500 from ~249.9s to ~160.9s but still lost to online default (~91.3s) and failed exact parity in comments/references/definitions/fragment_terms counts. Do not pursue deferred-term offline staging without first designing correct duplicate-fragment fact attribution semantics.
   - The current per-package flow runs many small staging/upsert/lookup cycles.
   - Explore N-package or shard-level fragment/code-fact buffers.
   - Preserve file/package context so quality does not regress.

3. **Prototype an offline build/finalize schema**
   - Initial helper exists as `Exograph.DuckDB.OfflineBuild`.
   - It appends fragments into a constraint-free `*_fragment_stage` table.
   - It finalizes by deduping staged rows by `content_hash`, inserting unique rows into `*_fragments`, and returning `content_hash => id` for staged fragments.
   - It can also stage files, terms, definitions, references, comments, fragment_terms, graph_nodes, and call_edges with `fragment_content_hash` and bind them to final IDs during finalization.
   - The helper is wired behind `--duckdb-build-mode offline` for initial package/corpus benchmarking.
   - A top-package parity test compares online vs offline row counts and representative searches.
   - A `top --limit 100` sharded smoke matched online totals but did not improve wall time, because files/terms are still finalized during per-package puts.
   - Offline call graph staging has a top10 `--reach` smoke and a top-package online/offline parity guard for graph node/call edge counts plus caller/callee searches.
   - A single-DB `top --limit 100 --reach` smoke completed for both online and offline; offline matched totals but was slower in wall time.
   - A sharded online + Reach run exposed a dynamic-repo issue in asynchronous call-graph inserts; async bulk insert tasks now preserve the current dynamic repo, and sharded online + Reach top10/top100 smokes pass.
   - A term-batching variant that staged term strings and resolved `fragment_terms` only during finalization passed parity but regressed `top --limit 100` wall time (`75s` vs `60s` adjacent online), because staging large per-fragment term-string payloads made `offline_build_stage_fragments` dominate. Keep term ID resolution during per-package puts until a lower-overhead representation is designed.
   - A hybrid variant that used online file upserts with offline fragment/fact staging also passed parity but remained slower (`73s` vs `62s` adjacent online), so file finalization was not the dominant unlock.
   - Next work: batch staging across larger units without inflating per-fragment payloads, finalize once per shard/corpus, then run larger quality parity checks.
   - Long-term finalization should:
     - dedupe fragments by `content_hash`
     - assign final IDs
     - join facts to final fragments
     - build indexes after bulk load.

4. **Delay integer fragment ID resolution**
   - Prefer stable identities during extraction, e.g. `content_hash` or `{file_id, line, hash}`.
   - Resolve integer `fragment_id` only in the finalization step.
   - This should remove much of the online `fragment_store_resolve_fragment_ids` pressure.

5. **Split online and offline DuckDB strategies**
   - Postgres and small DuckDB indexes can keep online Ecto-style insertion.
   - Large DuckDB corpora can use an offline analytical build pipeline if the public query API remains the same.

6. **Move proven patterns into QuackDB**
   - Keep Exograph code small and idiomatic.
   - If MERGE remains useful, make QuackDB's Ecto append path choose MERGE internally when DuckDB version/capability supports it.
   - Preserve Ecto semantics: conflicting existing rows should not be returned from `insert_all(..., returning: ...)` unless Ecto itself would return them.

## Non-goals for now

- Do not lower global search-quality thresholds for speed.
- Do not make package batching or MERGE default from one or two noisy runs.
- Do not add custom public `get_or_insert_all` APIs while normal Ecto operations can express the workload.
- Do not keep adding Exograph-local SQL builders when the shape belongs in QuackDB DML/adapter helpers.
