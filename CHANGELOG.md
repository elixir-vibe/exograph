# Changelog

## 0.8.1 - 2026-06-18

### Added

- Added sharded DuckDB semantics documentation and included it in published docs.
- Added safe DuckDB shard lifecycle helpers and manifest-open coverage.
- Added package-scoped sharded routing support for map, keyword, and `Exograph.PackageVersion` filters.
- Added sharded DuckDB web/CLI manifest usage documentation, including configurable shard port base for `mix exograph.web`.

### Fixed

- Fixed sharded DuckDB package-scoped text search filtering for DuckDB text-search paths.
- Fixed sharded web UI package counts by summing packages across shard indexes.
- Prevented manifest-owned but skipped packages from dropping package-version filters during sharded search.

## 0.8.0

### Added

- DuckDB/QuackDB is now the default backend for local indexing, search, and web tasks.
- Managed DuckDB options for Mix tasks: `--backend`, `--quackdb-uri`, `--quackdb-token`, `--duckdb-database`, `--duckdb-threads`, and Hex corpus sharding with `--duckdb-shards`.
- Dynamic sharded DuckDB corpus indexes with manifest persistence and fan-out query support.
- Direct DuckDB fragment append path using QuackDB APIs while preserving full persisted data.
- Backend benchmark harness with repeated runs, JSON reports, Postgres challenge-mode flags, EXPLAIN capture, randomized order, and automatic prefix cleanup.
- Backend benchmark and Postgres COPY staging design guides.

### Changed

- Switched to the published `quackdb ~> 0.5.3` dependency.
- Moved shared Ecto storage internals from the Postgres namespace to `Exograph.Storage.Ecto.*`.
- Split backend text-search paths into DuckDB and Postgres modules.
- Improved Postgres challenge-mode indexing with deferred non-unique query indexes and an additional `(file_id, line)` fragment index.
- Updated docs to frame benchmark results as Exograph backend/workload measurements, not universal database claims.

### Fixed

- Stabilized sharded DuckDB benchmark/server teardown by using unique shard port bases and stopping dynamic shard repos.
- Prevented local benchmark runs from leaving generated `bench_%` prefixes behind by default.

### Breaking / operational notes

- DuckDB/QuackDB is the default backend. Pass `backend: :postgres` or `--backend postgres` for existing Postgres workflows.
- Internal storage modules moved from `Exograph.Postgres.*` to `Exograph.Storage.Ecto.*`; code that referenced those internals should update module names.
- `bench-results/` is now gitignored; benchmark JSON and EXPLAIN files are local generated artifacts.

## 0.7.1

- Fixed Safari: editor content duplication after Run (morphdom updating `data-query` attribute on ignored div)
- Fixed Safari: arrow keys breaking after Run (`phx-update="ignore"` moved to outer wrapper with stable ID)
- Replaced "Load more" with numbered page pagination (Previous 1 2 … N Next)
- Fixed API controller pattern match for executor return tuple
- Added regression tests for editor functionality after search

## 0.7.0

- **37× faster joins**: LATERAL join for line-range containment replaces nested loop over all fragments
- **8× faster structural search**: `(kind, name, arity)` btree index bypasses GIN when pattern specifies a function name
- **2× faster text search**: file-first search with LATERAL fragment lookup instead of joining all fragments per file
- ParadeDB BM25 enabled by default (was opt-in)
- Fixed BM25 index creation: removed bigint columns incompatible with `pdb.literal` in ParadeDB 0.21+
- Fixed deadlock on concurrent term inserts: advisory lock per transaction instead of retry loop
- Recommended Postgres tuning settings documented (`max_parallel_workers_per_gather`, `shared_buffers`, `pg_prewarm`)
- Complete documentation rewrite: all guides updated for v0.7, hex indexing, performance tuning, architecture

## 0.6.0

- `mix exograph.index.hex` — download and index Hex.pm packages in a streaming pipeline
- Streaming: download tarball → extract to tmpdir → index → cleanup (disk = concurrency × 1 package)
- Resume by default: skips already-indexed packages by name+version
- Non-Elixir packages detected and skipped before disk write
- `--mode latest|top|all`, `--limit`, `--concurrency`, `--mirror`, `--cache-tarballs`
- CLI progress: per-package status icons, progress bar, rate, ETA
- LiveView progress dashboard at `/progress` via PubSub (use `--web` flag)
- Source viewer: click code icon to see full file with syntax highlighting and line highlight
- `pg_trgm` GIN indexes on `files.source` and `files.comments_text` for fast ILIKE
- Removed all full-table-scan fallbacks (ILIKE/regex in Postgres instead)
- Deadlock retry for concurrent term inserts
- Fixed non-semver version sorting in registry
- New deps: `hex_core ~> 0.15` (optional), `req ~> 0.5` (optional)

## 0.5.0

- Text and regex search modes in web UI and API (`mode: "text"` / `mode: "regex"`)
- `pg_trgm` GIN indexes on `files.source` and `files.comments_text` for fast ILIKE
- Replaced all full-table-scan fallbacks with Postgres ILIKE/regex queries
- Hex.pm source links on file paths (package version extracted from file paths)
- Source viewer modal — click the code icon to see full file with highlighted match line
- New guides: `web-ui.md`, `api.md`
- Updated README with Web UI, JSON API sections; Installation points to Hex
- Updated `querying.md` with text search, `mix-tasks.md` with `mix exograph.web`

## 0.4.1

- Upgraded Volt to 0.11.1, removed `oxc` override
- `module_types` configured in `config :volt` instead of hardcoded
- Asset builds use `mix volt.build` instead of internal Volt APIs
- Extracted Monaco bundling into a dedicated module

## 0.4.0

### Web UI

- Monaco editor with built-in Elixir syntax highlighting, auto-closing brackets, indentation
- Elixir intellisense via `Code.Fragment.cursor_context` — completes DSL macros, modules, fields
- IDE-style error diagnostics with red squiggly underlines and hover messages
- Format button via `Code.format_string!`
- Example query cards with descriptions
- Collapsible package groups, loading spinner, sticky editor
- URL query params (`?q=`) for shareable links
- Hex.pm links on package names
- Load more pagination
- Thin scrollbar via Tailwind v4.3 `scrollbar-thin`
- `phoenix_iconify` for icons

### API

- Cursor-based pagination (`cursor` param, `next_cursor` in response)
- Rate limiting via Hammer (`x-ratelimit-limit`, `x-ratelimit-remaining` headers, 429 on excess)

### Query engine

- DSL `limit:` clause parsed and respected
- Kind filtering — `def` patterns only match `def` fragments, not modules/expressions
- Keyset pagination replaces OFFSET in internal streaming (O(1) per page)
- Preview shows correct absolute line numbers

### Security

- Replaced `Code.eval_string` with safe AST interpreter (`SafeEval`)
- Dune sandbox for evaluating value expressions in predicates
- Dangerous code (`System.cmd`, `File.read!`, etc.) rejected at parse time

### Code quality

- Zero `any` in TypeScript — proper interfaces for Monaco, LiveView hooks
- `mix volt.js.check` (lint + format) added to CI
- Playwright feature tests for web UI (5 tests)
- API integration tests with Req (10 tests)
- Total: 50 unit + 15 feature = 65 tests

## 0.3.0

- Web UI with Monaco editor, syntax-highlighted search results, and autocompletion (`mix exograph.web`)
- JSON API: `POST /api/search`, `POST /api/query`, `GET /api/packages`, `GET /api/stats`
- Consolidated `Exograph.Postgres.*` namespace (FragmentStore, InvertedIndex, TreeStore)
- Renamed Query → StructuralQuery to disambiguate from DSL.Query
- Split DSL executor into focused modules (Predicates, Scope)
- Removed dead code: legacy Planner subtree, unused Indexer delegator
- Removed single-implementation behaviour modules (Extractor, FragmentStore, InvertedIndex, TreeStore)
- Simplified `Index` struct from 6 fields to 3

### Breaking

Module renames — update any direct references:
- `Exograph.FragmentStore.Postgres` → `Exograph.Postgres.FragmentStore`
- `Exograph.InvertedIndex.Postgres` → `Exograph.Postgres.InvertedIndex`
- `Exograph.TreeStore.Postgres` → `Exograph.Postgres.TreeStore`
- Query → StructuralQuery
- CodeFactQuery → Postgres.FactQuery

## 0.2.0

- Populate `fragment.module` with containing module name (97% coverage)
- Drop redundant `symbols` jsonb, `abstract_hash`, `mfa_*` columns
- Filter operator/structural noise from references (26% fewer rows)
- Use SHA-256 for content hash (32B vs 64B)
- Add `examples/index_hex_corpus.exs`

### Breaking

Schema changes require a fresh index. Drop existing tables and re-migrate.

## 0.1.0

Initial public release.

- Postgres-backed indexing for Elixir source code with integer primary keys and normalized terms
- ExAST-verified structural search with GIN term index acceleration
- Streaming batched fragment verification with early termination
- Normalized Ecto schemas for files, fragments, comments, definitions, references, packages, versions
- Optional Reach call graph extraction (graph nodes and call edges)
- Ecto-shaped DSL with fragment/definition/reference/call-edge sources
- Fragment joins with definitions, references, and call edges
- Multi-join fragment queries (up to 3 joins)
- Containing-function join semantics via precomputed `end_line`
- Fact-first join execution for selective predicates
- DSL plan validation (bindings, associations, structural predicates)
- Package/version-scoped indexing and queries
- Optional ParadeDB BM25 text/code-fact retrieval
- ExDNA structural similarity search
- Mix tasks for indexing and searching
- Tested against 2000 Hex packages (1.8M fragments, 5.5M references, 1M call edges)
