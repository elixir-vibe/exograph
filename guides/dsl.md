# Exograph DSL

`Exograph.DSL` is an Ecto-shaped query layer over fragments, definitions,
references, and Reach call edges.

```elixir
import Exograph.DSL
```

## Sources

Supported sources:

- `Fragment` — structural fragments verified by ExAST
- `Definition` — normalized definitions
- `Reference` — normalized references
- `CallEdge` — Reach-derived call edges

## Fragment queries

Fragment queries support structural predicates:

```elixir
query =
  from(f in Fragment,
    where: matches(f, "def _ do ... end"),
    where: contains(f, "Repo.transaction(_)")
  )

{:ok, results} = Exograph.all(index, query)
```

Fragment field predicates are also supported:

```elixir
from(f in Fragment,
  where: f.kind in [:def, :defp],
  where: f.mass > 4,
  where: contains(f, "Repo.transaction(_)")
)
```

## Definition, reference, and call-edge queries

```elixir
from(d in Definition,
  where: prefix_search(d.name, "parse_resp"),
  where: d.kind == :def
)

from(r in Reference,
  where: r.qualified_name == "Repo.transaction/1"
)

from(e in CallEdge,
  where: e.callee_qualified_name == "Repo.transaction/1"
)
```

These run directly against normalized DuckDB facts and return typed hits.

## Joins

Fragment queries can join normalized definitions, references, or Reach call
edges before ExAST verification:

```elixir
from(f in Fragment,
  join: r in assoc(f, :references),
  where: f.kind == :def,
  where: r.qualified_name == "Repo.transaction/1",
  where: matches(f, "def _ do ... end")
)
```

Definition queries can join call edges:

```elixir
from(d in Definition,
  join: e in assoc(d, :calls),
  where: d.kind == :defp,
  where: e.callee_qualified_name == "Repo.transaction/1"
)
```

## Multi-join fragment queries

Fragment queries can combine definitions, references, and calls:

```elixir
query =
  from(f in Fragment,
    join: d in assoc(f, :definitions),
    join: r in assoc(f, :references),
    join: e in assoc(f, :calls),
    where: d.kind == :defp,
    where: r.qualified_name == "Repo.transaction/1",
    where: e.callee_qualified_name == "Repo.transaction/1",
    where: matches(f, "defp _ do ... end"),
    select: {f, d, r, e}
  )

{:ok, [{hit, definition, reference, call_edge}]} = Exograph.all(index, query)
```

Fragment joins use containing-function semantics: facts from later functions do
not satisfy predicates on earlier fragments. When a definition join and a call
join are present, call edges are paired by caller qualified name.

## Selects

Joined fragment queries can select the fragment hit, a joined fact, or a tuple:

```elixir
from(f in Fragment,
  join: e in assoc(f, :calls),
  where: e.callee_qualified_name == "Repo.transaction/1",
  where: matches(f, "def _ do ... end"),
  select: {f, e}
)
```

## Planner validation

DSL queries are normalized through an internal plan before execution. The
planner validates unsupported sources, joins, duplicate bindings, unbound
predicates, structural predicates on non-fragment bindings, and invalid selects.
