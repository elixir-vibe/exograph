# Web UI

Exograph includes an embedded web interface powered by Phoenix LiveView and Monaco Editor.

## Starting

    mix exograph.web --prefix exograph --port 4200

| Option | Default | Description |
|--------|---------|-------------|
| `--repo` | — | Ecto repo module (uses built-in if omitted) |
| `--prefix` | `exograph` | Table prefix |
| `--port` | `4200` | HTTP port |

## Progress Dashboard

When running `mix exograph.index.hex --web`, a live progress dashboard is
available at `/progress`. It shows per-package status icons, a progress bar,
current rate (packages/s), and ETA. The dashboard is powered by Phoenix PubSub
and updates in real time without polling.

    mix exograph.index.hex --mode latest --concurrency 8 --web --port 4200
    # → open http://localhost:4200/progress

After indexing completes, the process stays running so the web UI remains
accessible for querying the freshly built index.

## Search Modes

**Structural** (default) — ExAST pattern matching:

    from(f in Fragment,
      where: matches(f, "def handle_call(_, _, _) do ... end"),
      limit: 20
    )

**Text** — full-text search in source code:

    TODO
    deprecated
    GenServer

**Regex** — regular expression search in source code:

    Repo\.get!\(
    def \w+!/\d

Toggle between modes with the Structural/Text/Regex buttons in the header.

## Editor Features

- Elixir syntax highlighting (Monaco built-in)
- Autocompletion for DSL macros (`from`, `matches`, `contains`), sources (`Fragment`, `Definition`), and field access
- Auto-closing brackets and quotes
- Cmd+Enter to run, Format button to reformat
- Error diagnostics with red underlines on the error line

## Results

Results are grouped by package, then by file:
- Package headers link to hex.pm and are collapsible
- File paths link to hex.pm package version
- Code previews show syntax-highlighted context around the match
- Click the code icon to open the full source file with the match line highlighted
- "Load more" button for pagination

## Dependencies

The web UI requires optional dependencies:

```elixir
{:phoenix, "~> 1.8"},
{:phoenix_html, "~> 4.1"},
{:phoenix_live_view, "~> 1.1"},
{:volt, "~> 0.11.1"},
{:bandit, "~> 1.5"},
{:makeup, "~> 1.0"},
{:makeup_elixir, "~> 1.0"},
{:phoenix_iconify, "~> 0.1"}
```

See [API](api.md) for the JSON API exposed by the same server.
