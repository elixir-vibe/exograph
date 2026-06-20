# Mix Tasks

## mix exograph.index

Index Elixir source files into DuckDB or Postgres.

    mix exograph.index --migrate lib
    mix exograph.index --migrate lib test
    mix exograph.index --prefix myindex --migrate --stats lib

| Option | Default | Description |
|--------|---------|-------------|
| `--repo` | — | Ecto repo module |
| `--prefix` | `exograph` | Table prefix |
| `--migrate` | false | Run migrations before indexing |
| `--no-bm25` | false | Skip ParadeDB BM25 index creation |
| `--min-mass` | `8` | Minimum AST fragment mass |
| `--stats` | false | Print fragment statistics after indexing |
| `--json` | false | Print summary as JSON |
| `--backend` | `duckdb` | `duckdb` or `postgres` |
| `--duckdb-database` | `exograph.duckdb` | Managed DuckDB database path when no QuackDB URI is provided |

## mix exograph.search

Structural, text, or regex search from the CLI.

    mix exograph.search 'Repo.get!(_, _)' --migrate lib
    mix exograph.search '/users/:id' --text lib
    mix exograph.search 'Repo\.get!\(' --regex lib

| Option | Default | Description |
|--------|---------|-------------|
| `--repo` | — | Ecto repo module |
| `--prefix` | `exograph` | Table prefix |
| `--migrate` | false | Run migrations before searching |
| `--no-bm25` | false | Skip ParadeDB BM25 index creation |
| `--min-mass` | `8` | Minimum AST fragment mass |
| `--limit` / `-n` | `20` | Maximum results |
| `--contains` | — | Require descendant pattern (repeatable) |
| `--not-contains` | — | Reject descendant pattern (repeatable) |
| `--no-verify` | false | Skip ExAST verification |
| `--text` | false | Literal text search |
| `--regex` | false | Regex text search |
| `--json` | false | Print results as JSON |
| `--backend` | `duckdb` | `duckdb` or `postgres` |
| `--duckdb-database` | `exograph.duckdb` | Managed DuckDB database path when no QuackDB URI is provided |

Structural search with predicates:

    mix exograph.search 'def _ do ... end' \
      --migrate lib \
      --contains 'Repo.transaction(_)' \
      --not-contains 'IO.inspect(_)'

## mix exograph.index.hex

Download and index Hex.pm packages in a streaming pipeline.

    mix exograph.index.hex
    mix exograph.index.hex --mode top --limit 5000
    mix exograph.index.hex --mode latest --duckdb-shards 4 --duckdb-threads 1 --prefix hex
    mix exograph.index.hex --mode latest --web --port 4200

| Option | Default | Description |
|--------|---------|-------------|
| `--mode` | `latest` | `latest`, `top`, or `all` |
| `--limit` | — | Max packages to index |
| `--prefix` | `hex` | Table prefix |
| `--concurrency` | `4` | Parallel download+index workers |
| `--backend` | `duckdb` | `duckdb` or `postgres` |
| `--duckdb-shards` | `1` | DuckDB shard count for corpus indexing |
| `--duckdb-threads` | — | DuckDB execution threads per server/shard |
| `--duckdb-recovery-mode` | — | Managed DuckDB recovery mode; use `no_wal_writes` for rebuildable indexes |
| `--manifest-path` | — | Write sharded DuckDB manifest ETF |
| `--shard-dir` | system temp | Directory for managed DuckDB shard files |
| `--min-mass` | `8` | Minimum AST fragment mass |
| `--reach` | false | Include Reach call graph extraction |
| `--force` | false | Re-index already-indexed packages |
| `--no-bm25` | false | Skip ParadeDB BM25 index creation |
| `--mirror` | `https://repo.hex.pm` | Tarball mirror URL (repeatable, round-robin) |
| `--registry-url` | first `--mirror` value | Hex registry URL for `versions`, `latest`, and `all` modes |
| `--api-url` | `https://hex.pm/api/packages` | Hex package API URL for `top` mode |
| `--cache-tarballs` | — | Directory to cache downloaded tarballs |
| `--database-url` | `EXOGRAPH_DATABASE_URL` | Postgres connection URL |
| `--quackdb-uri` | `QUACKDB_URI` | QuackDB URI for single DuckDB backend |
| `--quackdb-token` | `QUACKDB_TOKEN` | QuackDB token for single DuckDB backend |
| `--duckdb-database` | `hex.duckdb` | Managed DuckDB database path when no QuackDB URI is provided |
| `--repo` | — | Ecto repo module (uses built-in if omitted) |
| `--timeout` | `300` | Per-package timeout in seconds |
| `--web` | false | Start web UI with live progress dashboard |
| `--port` | `4200` | Web UI port (requires `--web`) |

When `--web` is set, the progress dashboard is available at `/progress` during indexing.
The process keeps running after indexing completes so the web UI remains accessible.

Already-indexed packages (by name+version) are skipped unless `--force` is given.
Peak disk usage is proportional to `--concurrency`, not total package count.

## mix exograph.web

Start a standalone web interface for exploring an index.

    mix exograph.web --prefix exograph --port 4200
    mix exograph.web --backend postgres --database-url postgres://localhost/mydb --prefix hex

| Option | Default | Description |
|--------|---------|-------------|
| `--backend` | `duckdb` | `duckdb` or `postgres` |
| `--repo` | — | Ecto repo module (uses built-in if omitted) |
| `--prefix` | `exograph` | Table prefix |
| `--port` | `4200` | HTTP port |
| `--database-url` | `EXOGRAPH_DATABASE_URL` | Postgres connection URL |
| `--quackdb-uri` | `QUACKDB_URI` | QuackDB URI |
| `--quackdb-token` | `QUACKDB_TOKEN` | QuackDB token |
| `--duckdb-database` | `exograph.duckdb` | Managed DuckDB database path when no QuackDB URI is provided |

Requires optional dependencies: `phoenix`, `phoenix_live_view`, `volt`, `bandit`.
See [Web UI](web-ui.md) for editor features, search modes, and API details.

## mix exograph.release_artifact

Build an Exograph OTP release tarball and ETF manifest for deployment tools such as HostKit.

    MIX_ENV=prod mix exograph.release_artifact --out-dir _build/prod/artifacts

| Option | Default | Description |
|--------|---------|-------------|
| `--out-dir` | `_build/prod/artifacts` | Directory for the release tarball and manifest |
| `--version` | `YYYYMMDD-gitsha` | Artifact version used in the tarball name |
| `--port` | `4200` | HTTP port recorded in the manifest and runtime env |
| `--health-path` | `/` | HTTP health path recorded in the manifest |

The task keeps Exograph-specific frontend prebuild work in Exograph: it installs locked npm packages, builds Volt assets, and then delegates the generic OTP release tarball and manifest creation to [ReleaseKit](https://hex.pm/packages/release_kit).

The output is compatible with `HostKit.Recipes.OTPRelease`:

    _build/prod/artifacts/exograph-20260620-abcdef0.tar.gz
    _build/prod/artifacts/exograph.etf
