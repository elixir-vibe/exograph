# Public Query Architecture

Exograph is a code-intelligence query and source-hydration engine. It indexes
code, plans indexed queries, returns lightweight entities, and hydrates
reproducible source snapshots. Consumers own semantic analysis and policy.

## Boundaries

Exograph owns the public logical query model, indexed planning, QuackDB/Ecto
physical compilation, execution, explicit source hydration, diagnostics, and
provenance. It does not execute arbitrary analyzer modules or own their finding
policy.

Reach integration is a consumer: it requests candidate package versions,
hydrates selected snapshots, and runs Reach outside Exograph's query engine.

## One logical query model

`Exograph.Query` is the stable contract shared by `Exograph.DSL`, JSON APIs,
local consumers, planners, and explain output. It is composed of JSONCodec-owned
structs with string bindings and a closed existing-atom vocabulary. Decoding
untrusted queries never creates atoms.

QuackDB schemas and `Ecto.Query` values are physical plans, not public query
contracts.

## First-class entities

The model includes packages, package versions, files, fragments, definitions,
references, and call edges. Queries return lightweight identities and metadata;
they never hydrate source implicitly.

## Explicit hydration

`Exograph.hydrate/3` converts a package-version identity into an immutable
`Exograph.SourceSnapshot`. Snapshots contain selected files, checksums,
completeness, an aggregate fingerprint, and index provenance.

## Planning and explanation

`Exograph.plan/1` returns a storage-independent `Exograph.Query.Plan`.
`Exograph.explain/3` reports that plan, required structural terms, execution
class, and index identity. Physical execution remains compiled through Ecto and
QuackDB.

## Hosted consumers

The hosted API accepts versioned query objects. DSL strings are an interactive
Elixir convenience, not the wire contract. Expensive consumer analyses should
run outside the hosted query process or through explicitly registered jobs.

## Pattern auditing

`Exograph.PatternAudit` verifies indexed structural patterns only. Project
construction and consumer-specific semantic verification do not belong in that
module.
