# Querying

Exograph supports structural search through ExAST selectors, DuckDB text/regex search, and relational queries through the DSL.

## Structural patterns

```elixir
{:ok, results} = Exograph.search(index, "Repo.get!(_, _)")
```

Patterns are plain ExAST patterns. `_` matches one node; `...` matches a sequence
or variable arity where supported by ExAST. DuckDB retrieves candidates by term index; ExAST verifies the structural match.

## Relationship-aware selectors

Use `ExAST.Query` when a single pattern is not enough:

```elixir
import ExAST.Query

query =
  from("def _ do ... end")
  |> where(contains("Repo.transaction(_)"))
  |> where(not contains("IO.inspect(_)"))

{:ok, results} = Exograph.search(index, query)
```

Selector alternatives, sibling/position predicates, comment predicates, and
capture guards are handled by ExAST. Exograph uses index terms as advisory
candidate filters and verifies the final result against the original AST/source.

```elixir
from(["def _ do ... end", "defp _ do ... end"])
|> where(follows("@doc _"))
|> where(first())

from("left == right")
|> where(^left == ^right)

from("def _ do ... end")
|> where(comment_before(text("transaction wrapper")))
```

## Text search

Search source code by literal text:

```elixir
{:ok, hits} = Exograph.search_text(index, "TODO")
{:ok, hits} = Exograph.search_text(index, "deprecated", limit: 50)
```

Text search uses DuckDB/QuackDB FTS to prefilter normalized identifier tokens
(such as qualified, snake-case, camel-case, and bang identifiers), followed by
an exact source-text check. Indexes created before this identifier index format
must be rebuilt.

## Regex search

Pass a compiled regex to `Exograph.search_text/3`:

```elixir
{:ok, hits} = Exograph.search_text(index, ~r/def \w+!/)
{:ok, hits} = Exograph.search_text(index, ~r/Repo\.(get|insert|update)!/, limit: 100)
```

Regex search uses QuackDB's DuckDB regular-expression helpers.

## Text and regex modes in the web UI and API

The web UI exposes Structural/Text/Regex toggle buttons. The JSON API accepts a
`mode` parameter:

```bash
curl -X POST http://localhost:4200/api/search \
  -H "Content-Type: application/json" \
  -d '{"pattern": "TODO", "mode": "text"}'

curl -X POST http://localhost:4200/api/search \
  -H "Content-Type: application/json" \
  -d '{"pattern": "Repo\\.get!\\(", "mode": "regex"}'
```

From the CLI:

    mix exograph.search 'TODO' --text --repo MyApp.Repo lib
    mix exograph.search 'Repo\.get!\(' --regex --repo MyApp.Repo lib

## Planning and explanations

Exograph treats indexes like an RDBMS treats access paths: advisory only. The
logical query remains the source of truth and every physical plan ends in exact
ExAST verification.

`Exograph.explain/3` exposes DuckDB's `EXPLAIN ANALYZE` output for the
candidate-retrieval SQL. It also reports separate candidate retrieval,
hydration, and ExAST verification metrics.

```elixir
Exograph.explain(index, "Repo.get!(User, id)", limit: 50)
#=> %{
#=>   logical: %{required_terms: ["call.remote:Repo.get!/2"], ...},
#=>   physical: %{
#=>     sql: "SELECT ...",
#=>     parameter_count: 2,
#=>     analyze: %QuackDB.Profile{}
#=>   },
#=>   metrics: %{candidate_rows: 150, hydrated_fragments: 150, matches: 12, ...}
#=> }
```

## Similarity prefiltering

Similarity uses indexed subhash candidates automatically at the default `0.8`
minimum similarity. Lower thresholds use a full scan to preserve recall. Override
the strategy when measuring or accepting the trade-off:

```elixir
Exograph.similar(index, source, prefilter: :subhash)
Exograph.similar(index, source, prefilter: :full_scan)
Exograph.similar(index, source, prefilter_min_similarity: 0.9)
```

`Exograph.explain_similarity/3` reports the chosen strategy and whether a
subhash lookup fell back to a full scan.

## Benchmark baseline

The deterministic query baseline is an opt-in integration test. It emits JSON
with `Exograph.explain/3` metrics and measured structural, one-/two-/three-join,
joined-keyset, text, and regex scenarios. Join cases also assert the expected
batched Ecto query count:

```bash
mix test test/integration/query_benchmark_test.exs --include benchmark
```

Use it before and after planner changes; candidate counts and verification
ratios are stable assertions, while elapsed times are informational.

To validate BM25 itself against a DuckDB server with the `fts` extension:

```bash
QUACKDB_FTS_TEST_URI=quack://host:port mix test test/integration/fts_text_search_test.exs --include fts
```

## Similarity search

Exograph stores ExDNA structural fingerprints for fragments and can rerank
similar fragments:

```elixir
{:ok, results} =
  Exograph.similar(index, """
  user
  |> cast(attrs, [:name])
  |> validate_required([:name])
  """, min_similarity: 0.8)
```
