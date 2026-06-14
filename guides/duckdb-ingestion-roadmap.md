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

This is intentionally idiomatic, but it still pays DuckDB unique/ART index maintenance and conflict checking during online ingestion.

An experimental MERGE path exists behind:

```bash
mix exograph.index.hex --duckdb-fragment-append merge ...
```

Early measurements show lower cumulative `fragment_append_rows` time, but end-to-end wall time is still noisy. Keep it experimental until repeated full-workload runs show a stable total-time win.

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

1. **Promote MERGE only with stronger evidence**
   - Repeat top2000/top5000 runs on a quiet machine.
   - Keep quality checks as benchmark assertions:
     - `Map.get(_, _)`
     - `Enum.map(_, _)`
     - `_ |> _`
     - package fragment counts such as `jason`.

2. **Increase ingestion flush granularity**
   - The current per-package flow runs many small staging/upsert/lookup cycles.
   - Explore N-package or shard-level fragment/code-fact buffers.
   - Preserve file/package context so quality does not regress.

3. **Prototype an offline build/finalize schema**
   - Initial helper exists as `Exograph.DuckDB.OfflineFragments`.
   - It appends fragments into a constraint-free `*_fragment_stage` table.
   - It finalizes by deduping staged rows by `content_hash`, inserting unique rows into `*_fragments`, and returning `content_hash => id` for staged fragments.
   - It can also stage definitions, references, comments, and fragment_terms with `fragment_content_hash` and bind them to final `fragment_id` during finalization.
   - Next work: extend the same idea to files, terms, and call graph facts, then wire a full package/corpus path for benchmarking.
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
