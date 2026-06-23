# Exograph

Local CodeQL-style code search for Elixir, backed by DuckDB/QuackDB and ExAST.

Exograph indexes Elixir source code into normalized Ecto-backed tables: files,
AST fragments, comments, definitions, references, package versions, and optional
Reach call graph facts. You can then query that index with structural AST
patterns, text/regex search, symbol/reference filters, and Ecto-shaped joins.

## What is Exograph?

Exograph is:

- a library for indexing Elixir source code into DuckDB through QuackDB
- a set of Ecto schemas and migrations for normalized code facts
- a structural search engine using ExAST for exact AST verification
- an optional Reach-backed call graph index
- a foundation for CodeQL-like Elixir queries over one project or many package versions

Exograph is not:

- a hosted search service
- a language server
- a general multi-language analyzer
- a replacement for ExAST or Reach

## Why?

Use Exograph when text search is not enough:

- find functions matching an AST shape
- search definitions and references across packages
- ask "which private functions call `Repo.transaction/1`?"
- index multiple Hex package versions into one database
- combine relational filters with exact ExAST verification
- persist Reach call graph facts for caller/callee queries

## Installation

```elixir
def deps do
  [
    {:exograph, "~> 0.7"}
  ]
end
```

DuckDB through QuackDB is the storage engine. Mix tasks can start a managed QuackDB server automatically, or you can pass an existing QuackDB-backed Ecto repo.

## Quickstart

Point Exograph at Elixir source. Mix tasks start a managed QuackDB server automatically unless you pass an existing QuackDB-backed Ecto repo:

```elixir
{:ok, index} =
  Exograph.index("lib",
    repo: MyApp.QuackDBRepo,
    migrate?: true
  )

{:ok, hits} = Exograph.search(index, "Repo.get!(_, _)")
```

DuckDB retrieves candidates by term index; ExAST verifies the structural match.

## Index Hex.pm

Download and index packages directly from Hex.pm:

    mix exograph.index.hex --mode latest --duckdb-shards 4 --duckdb-threads 1 --prefix hex

Use a Hex-compatible mirror for registry metadata and tarballs:

    mix exograph.index.hex --mode latest --mirror https://hex.elixir.toys --prefix hex

Modes: `latest` (one version per package), `top --limit 5000`, `all` (every version).
Resumes automatically — already-indexed packages are skipped.

For large corpora, DuckDB sharding keeps independent shard files and queries them through `%Exograph.ShardedIndex{}` without a merge step. Use `--manifest-path` to persist the shard manifest.

## Web UI

Exograph includes an embedded web interface for exploring indexes:

    mix exograph.web --prefix myindex --port 4200

Add `--web` to `mix exograph.index.hex` for a live progress dashboard while indexing runs.

Features:
- Monaco editor with Elixir syntax highlighting and autocompletion
- Structural, text, and regex search modes
- IDE-style error diagnostics
- Collapsible results grouped by package with code previews
- Hex.pm links on package names
- Live progress dashboard at `/progress` during Hex.pm indexing

## JSON API

The web server exposes a JSON API:

    POST /api/search   — structural, text, or regex search
    POST /api/query    — DSL query execution
    GET  /api/health   — app, release, runtime, and index health metadata
    GET  /api/packages — list indexed packages
    GET  /api/stats    — index statistics

Cursor pagination via `cursor`/`next_cursor`. Rate limited (60 req/min).

## Query with code facts

Use `Exograph.DSL` to combine structural AST patterns with indexed code facts:

```elixir
import Exograph.DSL

query =
  from(f in Fragment,
    join: r in assoc(f, :references),
    where: r.qualified_name == "Repo.transaction/1",
    where: matches(f, "def _ do ... end")
  )

{:ok, hits} = Exograph.all(index, query)
```

Reach call graph facts can also be queried directly:

```elixir
Exograph.search_callers(index, "Repo.transaction/1")
Exograph.search_callees(index, "MyApp.Accounts.update_user/2")
```

## How it compares

| Tool | Scope | Storage | Query style | Elixir AST-aware? | Best for |
|------|-------|---------|-------------|-------------------|----------|
| `ripgrep` | local text search | none | regex/text | no | fast ad-hoc text search |
| ExAST | structural AST matching | none/advisory terms | AST patterns/selectors | yes | exact search and patching |
| Reach | dependence analysis | in-memory graph/reports | APIs / Mix tasks | yes | call/data/control-flow analysis |
| CodeQL | semantic code analysis | CodeQL database | QL language | not first-class Elixir | security analysis at scale |
| Sourcegraph | cross-repo search | external index | text/structural depending setup | not Elixir-specific | organization-wide search |
| Exograph | Elixir code fact index | DuckDB/QuackDB | ExAST + Ecto-shaped DSL | yes | local/self-hosted Elixir code intelligence, large Hex package indexing |

## Features

- ExAST-backed structural search with exact verification
- normalized Ecto-backed storage for files, fragments, comments, definitions, references, packages, versions, and call edges
- `mix exograph.index.hex` — streaming pipeline to index all of Hex.pm
- package/version-scoped indexes for Hex or other source archives
- text and regex search via DuckDB/QuackDB
- optional Reach call graph extraction
- ExDNA-powered structural similarity
- web UI with Monaco editor, live progress dashboard, and JSON API

## Documentation

| Guide | Content |
|-------|---------|
| [Getting Started](guides/getting-started.md) | Installation, DuckDB setup, first index/search |
| [Querying](guides/querying.md) | Structural, text, and regex search; planning/explain |
| [DSL](guides/dsl.md) | `Exograph.DSL`, joins, selects, predicates |
| [Code Facts](guides/code-facts.md) | Definitions, references, comments, typed hits |
| [Call Graph](guides/call-graph.md) | Reach extraction, callers/callees, call edge DSL |
| [DuckDB and QuackDB](guides/duckdb.md) | Storage, sharding, manifests, tuning |
| [Package Indexing](guides/package-indexing.md) | Indexing Hex.pm and manual package archives |
| [Mix Tasks](guides/mix-tasks.md) | CLI indexing, searching, web UI |
| [Web UI](guides/web-ui.md) | Monaco editor, search modes, progress dashboard |
| [API](guides/api.md) | JSON API endpoints, pagination, rate limiting |
| [Comparisons](guides/comparisons.md) | Exograph vs ExAST, Reach, CodeQL, Sourcegraph |
| [Architecture](guides/architecture.md) | Storage model, verifier contract, extraction pipeline |

## Part of Elixir Vibe

Exograph indexes Elixir code — up to the entire public package ecosystem — for structural, AST-verified search.

It is one building block of a larger stack — tools that make AI-generated
software checkable: structural search, dependence analysis, duplication and
slop detection, session replay, and ecosystem-wide code search. See the
[Elixir Vibe](https://github.com/elixir-vibe) organization for the rest, and
[Building Blocks for the Future Web](https://github.com/elixir-vibe/building-blocks)
for the thesis, architecture, and roadmap that tie them together.

## License

MIT.
