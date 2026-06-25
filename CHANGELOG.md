# Changelog

## Unreleased

### Added

- Added `/api/health` with release, runtime, and index metadata for deployment readiness checks.
- Added web query and per-shard query telemetry with slow-query warnings.

### Changed

- Updated ReleaseKit configuration to `release_kit 0.2.1` and the `assets: [volt: ...]` pipeline.
- `POST /api/search` now accepts structural predicate shorthand such as `contains(f, def handle_event(_, _, _))`.
- Mirrored Exograph test paths under `test/exograph/` and documented the layout in `AGENTS.md`.
- Removed Exograph-owned raw DuckDB SQL assembly from text search, fragment append, migration backfill, and offline staging paths; compatibility flags now use the Ecto/QuackDB path.

## 0.9.0 - 2026-06-20

### Changed

- Removed the storage-engine selection layer; Exograph is DuckDB/QuackDB-only.
- Removed legacy database-specific Mix options, tests, docs, and implementation modules.
- Removed direct `fragment(...)` calls from Exograph source/test code in favor of Ecto DSL and QuackDB Ecto helpers.
- Configured ReleaseKit `0.1.1` with `ReleaseKit.Step.Volt` so release artifacts are built with `mix release_kit.artifact` directly.

### Fixed

- `POST /api/search` now executes DSL queries such as `from(f in Fragment, where: matches(f, "def handle_call(_, _, _) do ... end"), limit: 20)` instead of treating them as raw structural patterns.

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
