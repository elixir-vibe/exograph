# Call Graph

Exograph can persist Reach-derived call graph facts during indexing. Reach is an
optional library dependency and is used as an analysis engine; Exograph owns the
stable IDs, package/file scope, and DuckDB persistence.

## Enabling or disabling Reach

Reach extraction is enabled by default when the optional `:reach` dependency is
available.

Disable Reach when you only want ExAST facts:

```elixir
Exograph.index("lib",
  repo: MyApp.Repo,
  migrate?: true,
  extractors: [:ex_ast]
)
```

## Caller and callee search

```elixir
Exograph.search_callers(index, "Repo.transaction/1")
Exograph.search_callees(index, "MyApp.Accounts.update_user/2")
```

These return `%Exograph.CallEdgeHit{}` values.

## CallEdge DSL source

```elixir
import Exograph.DSL

from(e in CallEdge,
  where: e.callee_qualified_name == "Repo.transaction/1"
)
```

## Definition-to-call joins

Definition queries can join call edges by caller qualified name:

```elixir
from(d in Definition,
  join: e in assoc(d, :calls),
  where: d.kind == :defp,
  where: e.callee_qualified_name == "Repo.transaction/1"
)
```

Fragment queries can also join call edges before ExAST verification:

```elixir
from(f in Fragment,
  join: e in assoc(f, :calls),
  where: e.callee_qualified_name == "Repo.transaction/1",
  where: matches(f, "def _ do ... end")
)
```

When a fragment query joins both definitions and calls, Exograph pairs the call
edge with the definition's qualified name.

## Limitations

Reach is optional. If Reach is unavailable or disabled, call-edge tables may be
empty and caller/callee searches will not return semantic call graph facts.
