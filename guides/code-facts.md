# Code Facts

Exograph stores normalized code facts alongside AST fragments. These facts make
common code-intelligence queries fast and composable.

## Stored facts

Exograph extracts and persists:

- source files
- fragments
- comments
- definitions
- references
- graph nodes
- call edges

Facts include package/version/file scope so the same database can hold multiple
projects or package releases.

## Text and code-fact search

Literal source search uses the DuckDB/QuackDB text-search path. Regex search is verified against fragment source.

```elixir
Exograph.search_text(index, "/users/:id")
Exograph.search_text(index, ~r/Repo\.get!\(/)
Exograph.search_comments(index, "streaming chunks")
Exograph.search_definitions(index, "parse_resp")
Exograph.search_references(index, "Repo.transaction")
```

These return typed hit structs:

- `%Exograph.TextHit{}`
- `%Exograph.CommentHit{}`
- `%Exograph.DefinitionHit{}`
- `%Exograph.ReferenceHit{}`
- `%Exograph.CallEdgeHit{}`

## Definitions

Definitions include function/module kind, module/name/arity, qualified name,
source location, and scope IDs.

```elixir
import Exograph.DSL

query =
  from(d in Definition,
    where: d.kind == :defp,
    where: prefix_search(d.name, "parse")
  )

{:ok, definitions} = Exograph.all(index, query)
```

## References

References include local calls, remote calls, aliases, module attributes, and
MFA-style fields when available.

```elixir
from(r in Reference,
  where: r.qualified_name == "Repo.transaction/1"
)
```

## When to use facts vs structural search

Use code facts when you know the symbolic property you want:

- function name prefix
- qualified reference name
- definition kind
- call edge caller/callee

Use structural search when the AST shape matters:

- a function with a specific body pattern
- a pipeline shape
- a `case` or `with` form
- absence/presence of nested expressions

Use the DSL when you need both.
