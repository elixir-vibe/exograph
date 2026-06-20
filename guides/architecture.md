# Architecture

Exograph is built around one principle: storage and indexes are advisory; ExAST remains the semantic authority for structural matches.

## Components

- ExAST extracts structural terms, comments, symbols, and verifies patterns
- ExDNA provides structural fingerprints for fragments and similarity search
- Reach optionally extracts call graph facts
- Ecto-backed DuckDB/QuackDB storage persists normalized files, fragments, facts, package scope, and graph facts
- DuckDB FTS/BM25 can accelerate text retrieval

## Indexing pipeline

```txt
source files
  ├── ExAST extractor
  │   ├── fragments
  │   ├── comments
  │   ├── definitions
  │   └── references
  ├── Reach extractor (optional)
  │   ├── graph nodes
  │   └── call edges
  └── DuckDB/QuackDB storage
      ├── files
      ├── fragments
      ├── facts
      └── package/version scope
```

For Hex.pm indexing, an outer streaming loop wraps the pipeline:

```txt
Hex registry
  └── for each package (concurrent, bounded)
        ├── download tarball (HTTP, mirror round-robin)
        ├── detect Elixir files (skip non-Elixir before disk write)
        ├── extract to tmpdir
        ├── indexing pipeline (above)
        └── rm -rf tmpdir
```

## Storage model

`Exograph.Index` separates execution by concern:

- inverted index: structural term candidate retrieval from normalized DuckDB rows
- fragment store: AST blobs, ExDNA hashes, symbols, and file joins
- source files: source text and aggregated comment text stored once per file
- code facts: normalized comments, definitions, references, graph nodes, and call edges
- tree access: derived lazily from stored AST fragments
- verifier: `ExAST.Pattern` / `ExAST.Query`
- similarity: ExDNA structural reranking

## Query execution

Structural queries are planned into candidate retrieval plus verification:

```txt
ExAST selector
  ├── required/advisory terms
  ├── DuckDB candidate scan
  ├── hydrate fragments/source
  └── ExAST verification
```

DSL queries add relational candidate filters before structural verification:

```txt
Exograph.DSL.Query
  ├── Exograph.DSL.Plan validation
  ├── Ecto query over fragments/facts/calls
  ├── containing-function join semantics
  └── ExAST verification for fragment matches
```

## Lateral joins for line-range containment

The "containing function" join — find the `def` that contains a given fragment at line N — uses a SQL `LATERAL` subquery rather than a self-join. The lateral join evaluates the subquery once per outer row and uses the `(file_id, line, end_line)` index to locate the enclosing fragment in O(log n) per row. This keeps the containing-function semantic available without materializing a closure table.

## `(kind, name, arity)` btree index

Most structural patterns extract kind, name, and arity at query planning time (e.g. `def handle_call(_, _, _) do ... end` → kind=`def`, name=`handle_call`, arity=3). A btree index on `(kind, name, arity)` on the fragments table lets these queries bypass broader term scans and go to a targeted range scan, which is significantly faster at high fragment counts.

## File-first text search with lateral fragment lookup

Text and regex search operate file-first rather than fragment-first:

```txt
text query
  ├── scan files.source with DuckDB text/regex search
  ├── collect matching file IDs
  └── LATERAL join: for each file, find fragments containing the match line
```

This avoids storing duplicated source text per fragment and keeps `files.source` as the single source of truth. The lateral join uses the `(file_id, line, end_line)` btree index to locate the containing fragment efficiently.

## Sharded DuckDB

For large Hex.pm corpora, Exograph can index independent DuckDB shard files and query them through `%Exograph.ShardedIndex{}`. Sharding is explicit because it changes some global semantics: deduplication, ranking, and result pagination happen per shard before merge.

## Raw SQL boundary

Exograph uses Ecto where possible. Raw SQL remains only where DuckDB/QuackDB or Ecto cannot expose a needed primitive directly, such as schema/index DDL, table rewrites, extension setup, or bulk-load operations.
