defmodule Mix.Tasks.Exograph.Web do
  @moduledoc """
  Starts a standalone web interface for exploring an Exograph index.

      mix exograph.web --prefix exograph

  Options:

    * `--backend` — `duckdb` (default) or `postgres`
    * `--repo` — Ecto repo module (optional, uses built-in repo if omitted)
    * `--prefix` — table prefix (default: `exograph`)
    * `--port` — HTTP port (default: `4200`)
    * `--database-url` — Postgres URL (or set `EXOGRAPH_DATABASE_URL`)
    * `--quackdb-uri` — QuackDB URI (or starts managed DuckDB when omitted)
    * `--quackdb-token` — QuackDB token
    * `--duckdb-database` — managed DuckDB database path
    * `--manifest-path` — sharded DuckDB manifest path
    * `--duckdb-threads` — DuckDB execution threads per shard/server
    * `--duckdb-memory-limit` — DuckDB memory limit per shard/server, e.g. `2GB`
    * `--shard-pool-size` — DB connections per shard when opening a manifest

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
          shard_pool_size: :integer
        ]
      )

    backend = opts[:backend] || Mix.Exograph.BackendOptions.default_backend()
    prefix = opts[:prefix] || "exograph"
    port = opts[:port] || 4200

    Application.ensure_all_started(:exograph)
    Application.ensure_all_started(:phoenix)
    Application.ensure_all_started(:phoenix_live_view)

    {index, index_opts} = open_index!(backend, Keyword.put(opts, :prefix, prefix))

    Application.put_env(:exograph, :web_index, index)
    Application.put_env(:exograph, :web_repo, Keyword.fetch!(index_opts, :repo))
    Application.put_env(:exograph, :web_prefix, prefix)

    Exograph.Web.Server.put_endpoint_config(port)

    build_assets!()

    if Code.ensure_loaded?(Hammer) do
      Exograph.Web.RateLimiter.start_link([])
    end

    {:ok, _} = Exograph.Web.Server.start_pubsub_and_endpoint!()

    Mix.shell().info([
      "Exograph web running at ",
      IO.ANSI.cyan(),
      "http://localhost:#{port}",
      IO.ANSI.reset()
    ])

    unless iex_running?(), do: Process.sleep(:infinity)
  end

  defp open_index!("duckdb", opts) do
    case opts[:manifest_path] do
      nil ->
        index_opts = backend_opts("duckdb", opts)

        {:ok, index} =
          Exograph.index(
            [],
            Keyword.merge([backend: :duckdb, migrate?: false, bm25?: true], index_opts)
          )

        {index, index_opts}

      path ->
        {:ok, shards} =
          Exograph.DuckDBShards.open(path,
            duckdb_threads: opts[:duckdb_threads],
            duckdb_memory_limit: opts[:duckdb_memory_limit],
            pool_size: opts[:shard_pool_size] || 1
          )

        shard_indexes = Exograph.DuckDBShards.open_indexes(shards, bm25?: true)
        manifest = Exograph.DuckDBShards.load_manifest(path)
        index = Exograph.ShardedIndex.new(shard_indexes, manifest: manifest)
        {index, [repo: Exograph.DuckDBRepo, prefix: opts[:prefix]]}
    end
  end

  defp open_index!(backend, opts) do
    index_opts = backend_opts(backend, opts)

    {:ok, index} =
      Exograph.index(
        [],
        Keyword.merge(
          [backend: String.to_atom(backend), migrate?: false, bm25?: true],
          index_opts
        )
      )

    {index, index_opts}
  end

  defp backend_opts("postgres", opts) do
    repo_module = if opts[:repo], do: Module.concat([opts[:repo]]), else: Exograph.Web.Repo
    database_url = opts[:database_url] || System.get_env("EXOGRAPH_DATABASE_URL")

    repo_opts =
      if database_url do
        [url: database_url, pool_size: 5, ssl: false, log: false, timeout: 120_000]
      else
        Application.get_env(Mix.Project.config()[:app], repo_module, [])
        |> Keyword.merge(pool_size: 5, log: false, timeout: 120_000)
      end

    {:ok, _pid} = start_repo(repo_module, repo_opts)
    [repo: repo_module, prefix: opts[:prefix], bm25?: true]
  end

  defp backend_opts("duckdb", opts), do: Mix.Exograph.BackendOptions.backend_opts("duckdb", opts)

  defp backend_opts(other, _opts) do
    Mix.raise("Unknown backend #{inspect(other)}. Expected: postgres or duckdb")
  end

  defp start_repo(repo_module, opts) do
    case Process.whereis(repo_module) do
      nil ->
        if Code.ensure_loaded?(repo_module) do
          repo_module.start_link(opts)
        else
          Application.put_env(:exograph, Exograph.Web.Repo, opts)
          Exograph.Web.Repo.start_link(opts)
        end

      pid ->
        {:ok, pid}
    end
  end

  defp build_assets! do
    Exograph.Web.Monaco.ensure_bundled!()
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
        resolve_dirs: [Path.join(assets_root, "node_modules"), Path.join(@app_root, "deps")],
        module_types: %{".css" => :empty, ".ttf" => :empty},
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
