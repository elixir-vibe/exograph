# Changelog

## Unreleased

### Changed

- Updated ExAST to `0.12.6` for tagged identifier support in structural matching, candidate terms, and symbol extraction.
- Reworked Elixir parsing for indexed source to persist atom-free tagged identifiers instead of interning arbitrary package identifiers.
- Reworked storage to persist atom-free whole-file ASTs once on `files`, hydrate fragments by node locators, drop persisted fragment AST blobs and fragment term arrays, and remove the unused `tree_nodes` table.

### Fixed

- Hydrate persisted AST binaries with safe binary term decoding.
- Removed poisoned structural-name compatibility paths and stats now that identifier placeholders are no longer emitted.

## 0.9.5 - 2026-07-02

### Fixed

- Fixed a critical Hex-corpus parser/index poisoning bug where unknown package identifiers were silently replaced with `:__exograph_unknown_atom__`, causing structural search over the deployed Hex-wide index to return no matches for common patterns such as `Repo.get!(_, _)`.
- Added parser and indexing regression coverage asserting structural identifiers round-trip and `Repo.get!(_, _)` matches indexed package source.
- Added a `/api/stats` `poisoned_structural_names` counter so poisoned module/function names are visible in deployed indexes.
- Hardened API cursor decoding so malformed cursors fall back to the first page instead of raising.
- Production Hex reindex release tasks now refuse to publish staged indexes when package indexing errors remain, defaulting `EXOGRAPH_MAX_INDEX_ERRORS` to `0`.
- Broadway indexing failures now preserve failure reasons and retry transient timeout/transport failures raised outside normal package result handling.
- QuackDB shard repository transport receive/connect timeouts now default to `120s` and can be configured with `EXOGRAPH_QUACKDB_RECEIVE_TIMEOUT` / `EXOGRAPH_QUACKDB_CONNECT_TIMEOUT`.

## 0.9.4 - 2026-06-29

### Changed

- Updated ExAST to `0.12.4` so Reach source-smell audits can use explicit nil, small integer, and call-argument literal terms for narrower exact candidate filtering.

## 0.9.3 - 2026-06-29

### Fixed

- Rebuild sharded `fragment_terms` lookup tables after shard workers finish so staged Hex indexes publish with structural candidate lookups populated.

### Changed

- Updated ExAST to `0.12.3`.
- Reach source smell audits now use optional ExAST index terms during exact candidate filtering, allowing newly indexed literal terms to reduce verification work without changing findings.

## 0.9.2 - 2026-06-28

### Fixed

- Materialize deferred `fragment_terms` rows during Hex corpus finalization so structural and Reach audit candidate lookups work on freshly indexed shards.

## 0.9.1 - 2026-06-28

### Changed

- Hex corpus indexing now parses package source with existing-only static atoms by default to avoid unbounded atom table growth from arbitrary source literals.

## 0.9.0 - 2026-06-28

### Added

- Added `/api/health` with release, runtime, and index metadata for deployment readiness checks.
- Added web query and per-shard query telemetry with slow-query warnings.
- Added Reach source-smell audit tooling, including reporting summaries, comparison mode, configurable candidate selection, and examples.
- Added search execution metadata and lower-bound total reporting for broad DSL queries.

### Changed

- Removed the storage-engine selection layer; Exograph is DuckDB/QuackDB-only.
- Removed legacy database-specific Mix options, tests, docs, and implementation modules.
- Removed direct `fragment(...)` calls from Exograph source/test code in favor of Ecto DSL and QuackDB Ecto helpers.
- Updated ReleaseKit integration through `release_kit 0.3.1` and the `assets: [volt: ...]` artifact pipeline.
- Updated ExAST to `0.12.1`.
- `POST /api/search` now accepts structural predicate shorthand such as `contains(f, def handle_event(_, _, _))`.
- Improved web search result rendering with package-version hydration, named structural query totals, URL-persisted pagination, cleaner notices, and mobile layout refinements.
- Improved simple text search by using BM25 where available and pushing down text `contains` filters.
- Improved Reach audit performance with tuned defaults, parallel verification, lightweight candidate hydration, and skipped redundant exact candidate groups.
- Optimized structural term lookup by clustering the `fragment_terms` table and always optimizing structural indexes after corpus indexing.
- Reworked release reindexing to stage fresh shard builds before publishing manifests and reports.
- Renamed and centralized storage schema/table configuration, declared storage tables and indexes in schema modules, and split storage config from hydration.
- Mirrored Exograph test paths under `test/exograph/` and documented the layout in `AGENTS.md`.
- Removed Exograph-owned raw DuckDB SQL assembly from text search, fragment append, migration backfill, and offline staging paths.
- Removed stale DuckDB compatibility paths and updated DuckDB ingestion/deployment documentation.

### Fixed

- Fixed DSL queries such as `from(f in Fragment, where: matches(f, "def handle_call(_, _, _) do ... end"), limit: 20)` so they are not treated as raw structural patterns.
- Fixed fragment `matches/2` semantics after structural result display changes.
- Fixed PhoenixIconify release packaging/runtime behavior by configuring the OTP app and tracking the JSON manifest.
- Started `:inets` and the default `:httpc` profile during application boot so release tasks can fetch Hex registry data reliably.
- Included web asset sources in Hex packages so `mix exograph.web` can rebuild the UI from clean installs.

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

- DuckDB/QuackDB storage for local indexing, search, web tasks, and Hex corpus indexing.
- Managed DuckDB options for Mix tasks: `--quackdb-uri`, `--quackdb-token`, `--duckdb-database`, `--duckdb-threads`, and Hex corpus sharding with `--duckdb-shards`.
- Dynamic sharded DuckDB corpus indexes with manifest persistence and fan-out query support.
- Direct DuckDB fragment append path using QuackDB APIs while preserving full persisted data.

### Changed

- Switched to the published `quackdb` dependency.
- Moved shared storage internals to `Exograph.Storage.*` and renamed storage table helpers to `Exograph.Storage.Schema`.
- Updated docs around DuckDB/QuackDB corpus indexing and deployment.

### Fixed

- Stabilized sharded DuckDB benchmark/server teardown by using unique shard port bases and stopping dynamic shard repos.
- Prevented local benchmark runs from leaving generated prefixes behind by default.

## Older releases

Earlier releases introduced the web UI, JSON API, package indexing pipeline, code facts, DSL queries, ExAST-backed structural verification, optional Reach call graph extraction, and ExDNA structural similarity.
