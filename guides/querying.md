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

Text search uses the DuckDB/QuackDB text-search path.

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
ExAST verification unless you explicitly pass `verify: false`.

```elixir
plan =
  Exograph.plan(
    index,
    from("def _ do ... end") |> where(contains("Repo.get!(_, _)"))
  )

Exograph.explain(plan)
#=> %{
#=>   logical: %{required_terms: ["call.remote:Repo.get!/2"], ...},
#=>   physical: %{scan: {:term_index_scan, [...]}, filters: [:hydrate_fragments, :ex_ast_verify]},
#=>   estimated_candidates: 4,
#=>   warnings: []
#=> }
```

Standalone explanations are also available:

```elixir
Exograph.explain("Repo.get!(User, id)")
#=> %{required: ["call.remote:Repo.get!/2", ...], verifier: :pattern, ...}
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
