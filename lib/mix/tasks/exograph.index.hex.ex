defmodule Mix.Tasks.Exograph.Index.Hex do
  use Mix.Task

  @shortdoc "Index Hex.pm packages into Exograph"

  @moduledoc """
  Downloads and indexes Hex.pm packages into a DuckDB/QuackDB-backed Exograph index by default.

      mix exograph.index.hex
      mix exograph.index.hex --mode top --limit 5000
      mix exograph.index.hex --mode latest --concurrency 8
      mix exograph.index.hex --mode latest --web --port 4200

  Packages are downloaded as tarballs, extracted to a temp directory, indexed,
  then cleaned up. Peak disk usage is proportional to `--concurrency`, not the
  total number of packages.

  Already-indexed packages (by name+version) are skipped by default.
  Use `--force` to re-index everything.

  ## Options

    * `--mode` - `latest` (default), `top`, or `all`
    * `--limit` - max packages to index
    * `--entries-file` - JSON report or NDJSON file with `name` and `version` entries to index
    * `--entries-output-path` - write the resolved entry list as NDJSON for reproducible reruns
    * `--prefix` - table prefix (default: `hex`)
    * `--concurrency` - global download+index worker target (default: `4`)
    * `--package-batch-size` - packages to extract and flush together per worker (default: `1`)
    * `--shard-concurrency` - workers per DuckDB shard (default: `ceil(concurrency / duckdb_shards)`)
    * `--shard-pool-size` - DB connections per DuckDB shard (default: shard concurrency)
    * `--pipeline` - `task` (default) or `broadway`
    * `--duckdb-shards` - opt-in shard count for DuckDB corpus indexing. Sharding can improve large-corpus ingestion, but it has shard-local global search/count semantics; see `guides/sharded-duckdb.md`.
    * `--duckdb-threads` - DuckDB execution threads per shard/server
    * `--duckdb-memory-limit` - DuckDB memory limit per shard/server, e.g. `2GB`
    * `--duckdb-queue-target` - DBConnection queue target in milliseconds for DuckDB shard repos (default: `60000`)
    * `--duckdb-queue-interval` - DBConnection queue interval in milliseconds for DuckDB shard repos (default: `120000`)
    * `--duckdb-recovery-mode` - DuckDB managed-server recovery mode (`no_wal_writes` for rebuildable indexes)
    * `--duckdb-build-mode` - DuckDB corpus build strategy: `online` (default) or experimental `offline` metadata flag
    * `--duckdb-fragment-append` - DuckDB fragment insert strategy: `merge` (default) or `ecto`
    * `--duckdb-insert-buffer-size` - buffered DuckDB fact rows per table before flushing (default: `50000`)
    * `--manifest-path` - write a sharded DuckDB manifest to this path for `mix exograph.web --manifest-path ...`
    * `--report-path` - write indexing totals and failures as JSON
    * `--timings-path` - write stage timing totals as JSON
    * `--missing-tarballs-report-path` - write missing local tarballs as JSON when `--tarball-dir` is set
    * `--retry-count` - retry transient per-package failures this many times (default: `3`)
    * `--retry-sleep` - base retry sleep in milliseconds (default: `1000`)
    * `--shard-dir` - directory for managed DuckDB shard files
    * `--min-mass` - minimum fragment AST mass (default: `8`)
    * `--generated-min-mass` - minimum fragment AST mass for generated files (default: `16` for DuckDB, `8` for Postgres)
    * `--reach` - include Reach call graph extraction
    * `--force` - re-index already-indexed packages
    * `--no-bm25` - skip ParadeDB BM25 index creation
    * `--mirror` - tarball mirror URL (repeatable)
    * `--registry-url` - Hex registry URL for `versions`, `latest`, and `all` modes
    * `--api-url` - Hex package API URL for `top` mode
    * `--cache-tarballs` - directory to cache downloaded tarballs
    * `--tarball-dir` - local directory of Hex tarballs; bypasses HTTP tarball downloads
    * `--backend` - `duckdb` (default) or `postgres`
    * `--database-url` - Postgres URL (or set `EXOGRAPH_DATABASE_URL`)
    * `--postgres-maintenance-work-mem` - session-local maintenance_work_mem during Postgres index builds
    * `--postgres-max-parallel-maintenance-workers` - session-local max_parallel_maintenance_workers during Postgres index builds
    * `--postgres-unlogged` - use UNLOGGED Postgres tables for rebuildable local indexes
    * `--postgres-defer-indexes` - build non-unique Postgres query indexes after corpus loading
    * `--postgres-copy` - use Postgres COPY for supported high-volume append tables
    * `--quackdb-uri` - QuackDB URI for DuckDB backend (or set `QUACKDB_URI` / `QUACKDB_TEST_URI`)
    * `--quackdb-token` - QuackDB token for DuckDB backend (or set `QUACKDB_TOKEN` / `QUACKDB_TEST_TOKEN`)
    * `--duckdb-database` - managed DuckDB database path when `--quackdb-uri` is omitted
    * `--repo` - Ecto repo module (uses built-in if omitted)
    * `--timeout` - per-package timeout in seconds (default: `300`)
    * `--duckdb-fragment-payload-metrics` - record approximate per-column fragment append payload metrics
    * `--web` - start web UI with live progress dashboard
    * `--port` - web UI port (default: `4200`, requires `--web`)
  """

  @impl true
  def run(args) do
    Application.ensure_all_started(:postgrex)
    Application.ensure_all_started(:ecto_sql)
    Application.ensure_all_started(:req)

    {opts, _rest, invalid} =
      OptionParser.parse(args,
        strict: [
          backend: :string,
          mode: :string,
          limit: :integer,
          entries_file: :string,
          entries_output_path: :string,
          prefix: :string,
          concurrency: :integer,
          package_batch_size: :integer,
          shard_concurrency: :integer,
          shard_pool_size: :integer,
          pipeline: :string,
          duckdb_shards: :integer,
          duckdb_threads: :integer,
          duckdb_memory_limit: :string,
          duckdb_queue_target: :integer,
          duckdb_queue_interval: :integer,
          duckdb_recovery_mode: :string,
          duckdb_build_mode: :string,
          duckdb_fragment_append: :string,
          duckdb_fragment_payload_metrics: :boolean,
          duckdb_insert_buffer_size: :integer,
          manifest_path: :string,
          report_path: :string,
          timings_path: :string,
          missing_tarballs_report_path: :string,
          retry_count: :integer,
          retry_sleep: :integer,
          shard_dir: :string,
          min_mass: :integer,
          generated_min_mass: :integer,
          reach: :boolean,
          force: :boolean,
          no_bm25: :boolean,
          mirror: :keep,
          registry_url: :string,
          api_url: :string,
          cache_tarballs: :string,
          tarball_dir: :string,
          database_url: :string,
          postgres_maintenance_work_mem: :string,
          postgres_max_parallel_maintenance_workers: :integer,
          postgres_unlogged: :boolean,
          postgres_defer_indexes: :boolean,
          postgres_copy: :boolean,
          quackdb_uri: :string,
          quackdb_token: :string,
          duckdb_database: :string,
          repo: :string,
          timeout: :integer,
          web: :boolean,
          port: :integer
        ]
      )

    if invalid != [] do
      Mix.raise("Invalid options: #{inspect(invalid)}")
    end

    backend = backend!(Keyword.get(opts, :backend, Mix.Exograph.BackendOptions.default_backend()))
    repo = resolve_repo(backend, opts)
    prefix = Keyword.get(opts, :prefix, "hex")

    Exograph.Hex.Progress.start_link()

    if Keyword.get(opts, :web, false) do
      start_web!(backend, repo, prefix, opts)
    end

    mirrors = mirrors_from_opts(opts)
    registry_url = Keyword.get(opts, :registry_url, List.first(mirrors))

    extractors =
      if Keyword.get(opts, :reach, false), do: [:ex_ast, :reach], else: [:ex_ast]

    corpus_opts = [
      backend: backend,
      mode: String.to_atom(Keyword.get(opts, :mode, "latest")),
      limit: Keyword.get(opts, :limit),
      prefix: prefix,
      concurrency: Keyword.get(opts, :concurrency, 4),
      package_batch_size: Keyword.get(opts, :package_batch_size, 1),
      shard_concurrency: Keyword.get(opts, :shard_concurrency),
      shard_pool_size: Keyword.get(opts, :shard_pool_size),
      pipeline: pipeline(Keyword.get(opts, :pipeline)),
      shards: Keyword.get(opts, :duckdb_shards, 1),
      duckdb_threads: Keyword.get(opts, :duckdb_threads),
      duckdb_memory_limit: Keyword.get(opts, :duckdb_memory_limit),
      duckdb_queue_target: Keyword.get(opts, :duckdb_queue_target, 60_000),
      duckdb_queue_interval: Keyword.get(opts, :duckdb_queue_interval, 120_000),
      recovery_mode: recovery_mode(Keyword.get(opts, :duckdb_recovery_mode)),
      duckdb_build_mode: duckdb_build_mode(Keyword.get(opts, :duckdb_build_mode)),
      duckdb_fragment_append: duckdb_fragment_append(Keyword.get(opts, :duckdb_fragment_append)),
      duckdb_fragment_payload_metrics?:
        Keyword.get(opts, :duckdb_fragment_payload_metrics, false),
      duckdb_insert_buffer_size: Keyword.get(opts, :duckdb_insert_buffer_size, 50_000),
      manifest_path: Keyword.get(opts, :manifest_path),
      report_path: Keyword.get(opts, :report_path),
      timings_path: Keyword.get(opts, :timings_path),
      missing_tarballs_report_path: Keyword.get(opts, :missing_tarballs_report_path),
      entries_output_path: Keyword.get(opts, :entries_output_path),
      retry_count: Keyword.get(opts, :retry_count, 3),
      retry_sleep: Keyword.get(opts, :retry_sleep, 1_000),
      shard_directory: Keyword.get(opts, :shard_dir),
      min_mass: Keyword.get(opts, :min_mass, 8),
      generated_min_mass:
        Keyword.get(opts, :generated_min_mass, default_generated_min_mass(backend)),
      resume: not Keyword.get(opts, :force, false),
      bm25?: !Keyword.get(opts, :no_bm25, false),
      extractors: extractors,
      repo: repo,
      mirrors: mirrors,
      registry_url: registry_url,
      api_url: Keyword.get(opts, :api_url),
      mirror_strategy: :round_robin,
      timeout: Keyword.get(opts, :timeout, 300) * 1000,
      cache_dir: Keyword.get(opts, :cache_tarballs),
      tarball_dir: Keyword.get(opts, :tarball_dir),
      postgres_maintenance_work_mem: Keyword.get(opts, :postgres_maintenance_work_mem),
      postgres_max_parallel_maintenance_workers:
        Keyword.get(opts, :postgres_max_parallel_maintenance_workers),
      postgres_unlogged?: Keyword.get(opts, :postgres_unlogged, false),
      postgres_defer_indexes?: Keyword.get(opts, :postgres_defer_indexes, false),
      postgres_copy?: Keyword.get(opts, :postgres_copy, false)
    ]

    corpus_opts = put_entries(corpus_opts, Keyword.get(opts, :entries_file))

    result = Exograph.Hex.Corpus.index(corpus_opts)

    if Keyword.get(opts, :web, false) and is_map(result) and Map.has_key?(result, :index) do
      Application.put_env(:exograph, :web_index, result.index)
    end

    if Keyword.get(opts, :web, false) do
      Mix.shell().info(["\nIndexing complete. Web UI still running. Press Ctrl+C to stop."])
      unless iex_running?(), do: Process.sleep(:infinity)
    end
  end

  defp default_generated_min_mass(:duckdb), do: 16
  defp default_generated_min_mass(_backend), do: 8

  defp put_entries(opts, nil), do: opts
  defp put_entries(opts, path), do: Keyword.put(opts, :entries, entries_from_file(path))

  defp entries_from_file(path) do
    path
    |> File.read!()
    |> decode_entries(path)
  end

  defp decode_entries(content, path) do
    if String.ends_with?(path, ".json") do
      content
      |> Exograph.Hex.IndexReport.decode!()
      |> Map.fetch!(:failures)
      |> Enum.map(&entry_from_map!/1)
    else
      content
      |> String.split("\n", trim: true)
      |> Enum.map(&Jason.decode!/1)
      |> Enum.map(&entry_from_map!/1)
    end
  end

  defp entry_from_map!(%{"name" => name, "version" => version}) do
    %{name: name, version: version}
  end

  defp entry_from_map!(%Exograph.Hex.IndexReport.Failure{name: name, version: version}) do
    %{name: name, version: version}
  end

  defp entry_from_map!(%{name: name, version: version}) do
    %{name: name, version: version}
  end

  defp iex_running?, do: Code.ensure_loaded?(IEx) and IEx.started?()

  defp backend!("postgres"), do: :postgres
  defp backend!("duckdb"), do: :duckdb
  defp backend!(backend), do: Mix.raise("Unknown backend #{inspect(backend)}")

  defp pipeline(nil), do: :task
  defp pipeline("task"), do: :task
  defp pipeline("broadway"), do: :broadway
  defp pipeline(value), do: Mix.raise("Unknown pipeline #{inspect(value)}")

  defp recovery_mode(nil), do: nil
  defp recovery_mode("no_wal_writes"), do: :no_wal_writes
  defp recovery_mode(value), do: Mix.raise("Unknown DuckDB recovery mode #{inspect(value)}")

  defp duckdb_build_mode(nil), do: :online
  defp duckdb_build_mode("online"), do: :online
  defp duckdb_build_mode("offline"), do: :offline

  defp duckdb_build_mode(value) do
    Mix.raise("Unknown DuckDB build mode #{inspect(value)}; use online or offline")
  end

  defp duckdb_fragment_append(nil), do: :merge
  defp duckdb_fragment_append("ecto"), do: :ecto
  defp duckdb_fragment_append("merge"), do: :merge

  defp duckdb_fragment_append(value) do
    Mix.raise("Unknown DuckDB fragment append mode #{inspect(value)}; use ecto or merge")
  end

  defp resolve_repo(:postgres, opts) do
    case Keyword.get(opts, :repo) do
      nil ->
        database_url =
          Keyword.get(opts, :database_url) ||
            System.get_env("EXOGRAPH_DATABASE_URL") ||
            "postgres://localhost:5432/postgres"

        {:ok, _} =
          Exograph.Web.Repo.start_link(
            url: database_url,
            pool_size: 10,
            log: false,
            timeout: 120_000
          )

        Exograph.Web.Repo

      repo_str ->
        Mix.Task.run("app.start")
        Module.concat([repo_str])
    end
  end

  defp resolve_repo(:duckdb, opts) do
    case Keyword.get(opts, :repo) do
      nil ->
        Application.ensure_all_started(:ecto_sql)
        Application.ensure_all_started(:quackdb)

        if Keyword.get(opts, :duckdb_shards, 1) <= 1 do
          Application.put_env(:exograph, Exograph.DuckDBRepo,
            uri:
              Keyword.get(opts, :quackdb_uri) || System.get_env("QUACKDB_URI") ||
                System.get_env("QUACKDB_TEST_URI") || start_managed_duckdb!(opts),
            token: Mix.Exograph.BackendOptions.duckdb_token(opts),
            pool_size: Keyword.get(opts, :concurrency, 4),
            telemetry_prefix: [:quackdb],
            log: false,
            timeout: 120_000
          )

          {:ok, _} = Exograph.DuckDBRepo.start_link()
        end

        Exograph.DuckDBRepo

      repo_str ->
        Mix.Task.run("app.start")
        Module.concat([repo_str])
    end
  end

  defp start_managed_duckdb!(opts) do
    token = Mix.Exograph.BackendOptions.duckdb_token(opts)
    endpoint = "quack:127.0.0.1:#{Mix.Exograph.BackendOptions.free_tcp_port!()}"

    server_opts =
      [
        duckdb: :managed,
        database:
          Keyword.get(opts, :duckdb_database, "#{Keyword.get(opts, :prefix, "hex")}.duckdb"),
        endpoint: endpoint,
        token: token,
        settings: Mix.Exograph.BackendOptions.duckdb_settings(Keyword.get(opts, :duckdb_threads))
      ]
      |> put_optional(:recovery_mode, recovery_mode(Keyword.get(opts, :duckdb_recovery_mode)))

    {:ok, server} = QuackDB.Server.start_link(server_opts)

    QuackDB.Server.uri(server)
  end

  defp put_optional(opts, _key, nil), do: opts
  defp put_optional(opts, key, value), do: Keyword.put(opts, key, value)

  defp start_web!(backend, repo, prefix, opts) do
    port = Keyword.get(opts, :port, 4200)

    Application.ensure_all_started(:phoenix)
    Application.ensure_all_started(:phoenix_live_view)

    {:ok, index} =
      Exograph.index([],
        backend: backend,
        repo: repo,
        prefix: prefix,
        migrate?: false,
        bm25?: !Keyword.get(opts, :no_bm25, false)
      )

    Application.put_env(:exograph, :web_index, index)
    Application.put_env(:exograph, :web_repo, repo)
    Application.put_env(:exograph, :web_prefix, prefix)

    Exograph.Web.Server.put_endpoint_config(port)

    File.rm_rf!(Volt.Config.build().outdir)
    Mix.Task.rerun("volt.build")

    if Code.ensure_loaded?(Hammer), do: Exograph.Web.RateLimiter.start_link([])

    {:ok, _} = Exograph.Web.Server.start_pubsub_and_endpoint!()

    Mix.shell().info([
      "Progress dashboard at ",
      IO.ANSI.cyan(),
      "http://localhost:#{port}/progress",
      IO.ANSI.reset()
    ])
  end

  defp mirrors_from_opts(opts) do
    case Keyword.get_values(opts, :mirror) do
      [] -> ["https://repo.hex.pm"]
      mirrors -> mirrors
    end
  end
end
