# Mix Tasks

## mix exograph.index

Index Elixir source files into DuckDB through QuackDB.

    mix exograph.index --migrate lib
    mix exograph.index --migrate lib test
    mix exograph.index --prefix myindex --migrate --stats lib

| Option | Default | Description |
|--------|---------|-------------|
| `--repo` | — | QuackDB-backed Ecto repo module |
| `--prefix` | `exograph` | Table prefix |
| `--migrate` | false | Run DuckDB migrations before indexing |
| `--no-bm25` | false | Skip DuckDB BM25/FTS index creation |
| `--min-mass` | `8` | Minimum AST fragment mass |
| `--stats` | false | Print fragment statistics after indexing |
| `--json` | false | Print summary as JSON |
| `--quackdb-uri` | `QUACKDB_URI` | QuackDB URI when no repo is provided |
| `--quackdb-token` | `QUACKDB_TOKEN` | QuackDB token |
| `--duckdb-database` | `exograph.duckdb` | Managed DuckDB database path when no QuackDB URI is provided |

## mix exograph.search

Structural, text, or regex search from the CLI.

    mix exograph.search 'Repo.get!(_, _)' --migrate lib
    mix exograph.search '/users/:id' --text lib
    mix exograph.search 'Repo\.get!\(' --regex lib

| Option | Default | Description |
|--------|---------|-------------|
| `--repo` | — | QuackDB-backed Ecto repo module |
| `--prefix` | `exograph` | Table prefix |
| `--migrate` | false | Run DuckDB migrations before searching |
| `--no-bm25` | false | Skip DuckDB BM25/FTS index creation |
| `--min-mass` | `8` | Minimum AST fragment mass |
| `--limit` / `-n` | `20` | Maximum results |
| `--contains` | — | Require descendant pattern (repeatable) |
| `--not-contains` | — | Reject descendant pattern (repeatable) |
| `--no-verify` | false | Skip ExAST verification |
| `--text` | false | Literal text search |
| `--regex` | false | Regex text search |
| `--json` | false | Print results as JSON |
| `--quackdb-uri` | `QUACKDB_URI` | QuackDB URI when no repo is provided |
| `--quackdb-token` | `QUACKDB_TOKEN` | QuackDB token |
| `--duckdb-database` | `exograph.duckdb` | Managed DuckDB database path when no QuackDB URI is provided |

Structural search with predicates:

    mix exograph.search 'def _ do ... end' \
      --migrate lib \
      --contains 'Repo.transaction(_)' \
      --not-contains 'IO.inspect(_)'

## mix exograph.index.hex

Download and index Hex.pm packages in a streaming DuckDB pipeline.

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
| `--duckdb-shards` | `1` | DuckDB shard count for corpus indexing |
| `--duckdb-threads` | — | DuckDB execution threads per server/shard |
| `--duckdb-recovery-mode` | — | Managed DuckDB recovery mode; use `no_wal_writes` for rebuildable indexes |
| `--manifest-path` | — | Write sharded DuckDB manifest ETF |
| `--shard-dir` | system temp | Directory for managed DuckDB shard files |
| `--min-mass` | `8` | Minimum AST fragment mass |
| `--reach` | false | Include Reach call graph extraction |
| `--force` | false | Re-index already-indexed packages |
| `--no-bm25` | false | Skip DuckDB BM25/FTS index creation |
| `--mirror` | `https://repo.hex.pm` | Tarball mirror URL (repeatable, round-robin) |
| `--registry-url` | first `--mirror` value | Hex registry URL for `versions`, `latest`, and `all` modes |
| `--api-url` | `https://hex.pm/api/packages` | Hex package API URL for `top` mode |
| `--cache-tarballs` | — | Directory to cache downloaded tarballs |
| `--quackdb-uri` | `QUACKDB_URI` | QuackDB URI for single DuckDB indexing |
| `--quackdb-token` | `QUACKDB_TOKEN` | QuackDB token |
| `--duckdb-database` | `hex.duckdb` | Managed DuckDB database path when no QuackDB URI is provided |
| `--repo` | — | QuackDB-backed Ecto repo module |
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
    mix exograph.web --manifest-path priv/exograph/hex.etf --port 4200

| Option | Default | Description |
|--------|---------|-------------|
| `--repo` | — | QuackDB-backed Ecto repo module |
| `--prefix` | `exograph` | Table prefix |
| `--port` | `4200` | HTTP port |
| `--quackdb-uri` | `QUACKDB_URI` | QuackDB URI |
| `--quackdb-token` | `QUACKDB_TOKEN` | QuackDB token |
| `--duckdb-database` | `exograph.duckdb` | Managed DuckDB database path |
| `--manifest-path` | — | Sharded DuckDB manifest path |

Requires optional dependencies: `phoenix`, `phoenix_live_view`, `volt`, `bandit`.
See [Web UI](web-ui.md) for editor features, search modes, and API details.

## Release artifacts

Build frontend assets first, then use [ReleaseKit](https://hex.pm/packages/release_kit) directly to produce the OTP release tarball and ETF manifest:

    MIX_ENV=prod mix run --no-start -e 'Application.ensure_all_started(:req); File.cd!("assets", fn -> NPM.install(production: true, frozen: true) end); File.rm_rf!(Volt.Config.build().outdir)'
    MIX_ENV=prod mix volt.build
    MIX_ENV=prod mix release_kit.artifact --out-dir _build/prod/artifacts --port 4200 --health-path /

ReleaseKit owns the generic OTP artifact format. Exograph does not wrap ReleaseKit; deployment tools such as `HostKit.Recipes.OTPRelease` consume the generated manifest directly:

    _build/prod/artifacts/exograph-20260620-abcdef0.tar.gz
    _build/prod/artifacts/exograph.etf
