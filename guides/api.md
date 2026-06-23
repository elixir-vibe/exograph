# JSON API

When running `mix exograph.web`, a JSON API is available alongside the web UI.

## Endpoints

### POST /api/search

Structural or text search.

    curl -X POST http://localhost:4200/api/search \
      -H "Content-Type: application/json" \
      -d '{"pattern": "Repo.get!(_, _)", "limit": 10}'

Parameters:
- `pattern` (required) — search pattern or text query
- `mode` — `"structural"` (default), `"text"`, or `"regex"`
- `limit` — max results (default: 50, max: 200)
- `cursor` — pagination cursor from previous response
- `package_id` — scope to a specific package

Response:

    {
      "results": [{"type": "def", "file": "lib/repo.ex", "package": "ecto", ...}],
      "count": 10,
      "elapsed_ms": 23.4,
      "next_cursor": "MTA"
    }

### POST /api/query

Execute a DSL query.

    curl -X POST http://localhost:4200/api/query \
      -H "Content-Type: application/json" \
      -d '{"query": "from(d in Definition, where: d.kind == :def, where: prefix_search(d.name, \"handle\"))"}'

Parameters:
- `query` (required) — DSL query string
- `cursor` — pagination cursor

### GET /api/health

Runtime health and deployment metadata.

    curl http://localhost:4200/api/health

Response includes the application version, release path/name, runtime metadata, and index shape such as `kind`, `shard_count`, and `opened_shards`. HostKit readiness checks can use this endpoint to verify the API and opened index, not just the HTML route.

### GET /api/packages

List indexed packages sorted by fragment count.

    curl http://localhost:4200/api/packages

### GET /api/stats

Index statistics.

    curl http://localhost:4200/api/stats

## Telemetry

Web search requests emit `[:exograph, :web, :query, :stop]` with `duration_ms` and `returned` measurements plus endpoint, query kind, status, and truncated query metadata.

Sharded fanout emits `[:exograph, :shard, :query, :stop]` with per-shard duration, returned count, function, shard identity, and status metadata. Queries slower than the configured thresholds are also logged as warnings.

## Rate Limiting

The API is rate limited to 60 requests per minute per IP.
Headers `x-ratelimit-limit` and `x-ratelimit-remaining` are included in responses.
Exceeding the limit returns HTTP 429.

## Security

Query execution uses a safe AST interpreter — no `Code.eval_string`.
Dangerous operations (`System.cmd`, `File.read!`, etc.) are rejected at parse time.
Value expressions in predicates are evaluated through the Dune sandbox.
