# DuckDB ingestion roadmap

This note tracks longer-horizon ideas for Exograph's DuckDB Hex-corpus builder. The current constraint is simple: Exograph should express storage work with Ecto and existing QuackDB APIs. If a future optimization needs DuckDB-specific SQL, add the missing abstraction to QuackDB first and consume that API from Exograph.

## Current state

The default DuckDB path uses Ecto/QuackDB APIs:

```elixir
Repo.insert_all(FragmentRecord, rows,
  insert_method: :append,
  on_conflict: :nothing,
  conflict_target: [:content_hash],
  returning: [:id, :content_hash]
)
```

The previous Exograph-local MERGE and offline staging paths were removed because they made Exograph own raw DuckDB SQL assembly. Fragment insertion, text search, schema migrations, and tests now use Ecto query/migration APIs or existing QuackDB helpers.

For reproducible topN runs, write the resolved package list with `--entries-output-path` and rerun with `--entries-file` instead of relying on a live top list.

## Ingestion decision checkpoint

The current default is **single-DuckDB online Ecto/QuackDB append**. It preserves the public single-index semantics and avoids Exograph-owned raw SQL.

Sharded DuckDB is **not a drop-in replacement** for the default. It is the fastest large-corpus ingestion shape observed so far, but shard-local fragment/content/term identity changes global semantics: fragment/term counts increase, broad structural queries can over-count, and a simple fanout dedup by fragment hash did not restore parity. Treat sharding as an opt-in/product-level read architecture candidate with explicit shard-local/global semantics, not as an invisible performance flag. See [Sharded DuckDB semantics](sharded-duckdb.md) for the current contract.

The future winning architecture should be chosen by product semantics rather than another per-package micro-benchmark:

- **Sharded read architecture**: keep independent DuckDB shard files, accept shard-local IDs/dedup where appropriate, add tests for package-scoped parity, and redesign global search/ranking/aggregation semantics explicitly.
- **Global finalization pipeline**: extract/index packages into fast staging units or shards, then perform global fragment/term/fact finalization into one logical index. This preserves single-index semantics but requires a correct duplicate-fragment fact attribution model. Build this only through Ecto or QuackDB-owned APIs.

## Stop-list

Do not reintroduce these as Exograph-local SQL paths:

- local MERGE/temp-table fragment append;
- offline deferred term staging;
- Exograph-owned `INSERT INTO ... SELECT ...` finalization;
- direct QuackDB append bypass through active-transaction internals;
- persistent non-temp staging tables;
- coarse transaction-level fragment append semaphores;
- simple fragment-stage chunk tuning as a standalone optimization;
- simple sharded fanout dedup by fragment hash.

## Roadmap

1. **Keep storage paths Ecto/QuackDB-shaped**
   - Prefer Ecto query and migration APIs.
   - Prefer existing QuackDB helpers such as `QuackDB.DDL`, `QuackDB.DML`, `QuackDB.FTS`, and native append options.
   - Add a QuackDB helper only after existing APIs cannot express the required behavior cleanly.

2. **Watch current Ecto append performance**
   - Use fixed package lists and local fixtures.
   - Compare correctness before timing.
   - Track row volumes and flush timings before adding more buffering.

3. **Continue sharded query semantics work**
   - Keep sharding explicit.
   - Avoid post-query dedup as a correctness patch.
   - Define honest exact/estimated totals per query shape.

4. **Consider a future QuackDB-owned finalization API only if needed**
   - It must preserve Exograph result semantics.
   - It should expose typed inputs/options rather than asking Exograph to assemble SQL.
   - It should be justified by local benchmark evidence, not assumed.
