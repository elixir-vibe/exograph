defmodule Mix.Tasks.Exograph.Web do
  @moduledoc """
  Starts a standalone web interface for exploring an Exograph index.

      mix exograph.web --prefix exograph
      mix exograph.web --manifest-path data/hex-shards/manifest.term

  Options:

    * `--backend` — `duckdb` (default) or `postgres`
    * `--repo` — Ecto repo module (optional, uses built-in repo if omitted)
    * `--prefix` — table prefix (default: `exograph`)
    * `--port` — HTTP port (default: `4200`)
    * `--database-url` — Postgres URL (or set `EXOGRAPH_DATABASE_URL`)
    * `--quackdb-uri` — QuackDB URI (or starts managed DuckDB when omitted)
    * `--quackdb-token` — QuackDB token
    * `--duckdb-database` — managed DuckDB database path
    * `--manifest-path` — sharded DuckDB manifest path from `mix exograph.index.hex --manifest-path ...`
    * `--duckdb-threads` — DuckDB execution threads per shard/server
    * `--duckdb-memory-limit` — DuckDB memory limit per shard/server, e.g. `2GB`
    * `--shard-pool-size` — DB connections per shard when opening a manifest
    * `--shard-port-base` — first local QuackDB port when opening a sharded manifest (default: `9700`)

  """
  use Mix.Task

  @app_root Path.expand("../../..", __DIR__)

  @impl true
  def run(args) do
    ensure_web_dependencies!()
    put_volt_config!()

    {opts, _, _} =
      OptionParser.parse(args,
        strict: [
          backend: :string,
          repo: :string,
          prefix: :string,
          port: :integer,
          database_url: :string,
          quackdb_uri: :string,
          quackdb_token: :string,
          duckdb_database: :string,
          manifest_path: :string,
          duckdb_threads: :integer,
          duckdb_memory_limit: :string,
          shard_pool_size: :integer,
          shard_port_base: :integer
        ]
      )

    backend = opts[:backend] || Mix.Exograph.BackendOptions.default_backend()
    prefix = opts[:prefix] || "exograph"
    port = opts[:port] || 4200

    Application.ensure_all_started(:exograph)

    build_assets!()

    runtime_opts =
      opts
      |> Keyword.put(:backend, backend)
      |> Keyword.put(:prefix, prefix)
      |> Keyword.put(:port, port)

    {:ok, _} = Exograph.Web.Runtime.start_link(runtime_opts)

    Mix.shell().info([
      "Exograph web running at ",
      IO.ANSI.cyan(),
      "http://localhost:#{port}",
      IO.ANSI.reset()
    ])

    unless iex_running?(), do: Process.sleep(:infinity)
  end

  defp build_assets! do
    Mix.Task.rerun("volt.build")
  end

  defp put_volt_config! do
    assets_root = Path.join(@app_root, "assets")

    Application.put_all_env(
      volt: [
        entry: Path.join(@app_root, "assets/web/app.ts"),
        root: assets_root,
        outdir: Path.join(@app_root, "priv/static/assets"),
        target: :es2020,
        hash: false,
        asset_url_prefix: "/assets/js",
        resolve_dirs: [Path.join(assets_root, "node_modules"), Path.join(@app_root, "deps")],
        module_types: %{".css" => :empty, ".ttf" => :asset},
        tailwind: [
          css: Path.join(@app_root, "assets/web/app.css"),
          sources: [
            %{base: Path.join(@app_root, "lib"), pattern: "**/*.{ex,heex}"},
            %{base: assets_root, pattern: "**/*.{ts,css}"}
          ]
        ],
        server: [
          prefix: "/assets",
          watch_dirs: [Path.join(@app_root, "lib"), assets_root]
        ]
      ]
    )
  end

  defp ensure_web_dependencies! do
    missing =
      [
        {:phoenix, Phoenix},
        {:phoenix_live_view, Phoenix.LiveView},
        {:volt, Volt},
        {:volt, Volt.Config},
        {:bandit, Bandit}
      ]
      |> Enum.reject(fn {_app, module} -> Code.ensure_loaded?(module) end)
      |> Enum.map(fn {app, _module} -> app end)
      |> Enum.uniq()

    if missing != [] do
      deps =
        missing
        |> Enum.map_join(", ", fn app -> "{:#{app}, \"...\"}" end)

      Mix.raise("mix exograph.web requires these dependencies in the host project: #{deps}")
    end
  end

  defp iex_running?, do: Code.ensure_loaded?(IEx) and IEx.started?()
end
