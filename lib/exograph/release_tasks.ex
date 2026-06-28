defmodule Exograph.ReleaseTasks do
  @moduledoc false

  def index_hex_from_env do
    Application.ensure_all_started(:exograph)
    Application.ensure_all_started(:ecto_sql)
    Application.ensure_all_started(:req)

    final_manifest_path = System.fetch_env!("EXOGRAPH_MANIFEST")
    final_report_path = System.fetch_env!("EXOGRAPH_REPORT")
    final_shard_dir = System.fetch_env!("EXOGRAPH_SHARD_DIR")
    build = staged_build_paths(final_shard_dir)

    opts = [
      mode: :latest,
      prefix: env("EXOGRAPH_PREFIX", "hex"),
      concurrency: env_integer("EXOGRAPH_INDEX_CONCURRENCY", 8),
      shard_concurrency: env_integer("EXOGRAPH_SHARD_CONCURRENCY", 1),
      shard_pool_size: env_integer("EXOGRAPH_SHARD_POOL_SIZE", 1),
      pipeline: :broadway,
      shards: env_integer("EXOGRAPH_DUCKDB_SHARDS", 8),
      duckdb_threads: env_integer("EXOGRAPH_DUCKDB_THREADS", 2),
      duckdb_memory_limit: env("EXOGRAPH_DUCKDB_MEMORY_LIMIT", "2GB"),
      duckdb_queue_target: env_integer("EXOGRAPH_DUCKDB_QUEUE_TARGET", 60_000),
      duckdb_queue_interval: env_integer("EXOGRAPH_DUCKDB_QUEUE_INTERVAL", 120_000),
      manifest_path: build.manifest_path,
      report_path: build.report_path,
      shard_directory: build.shard_dir,
      retry_count: env_integer("EXOGRAPH_RETRY_COUNT", 3),
      retry_sleep: env_integer("EXOGRAPH_RETRY_SLEEP", 1_000),
      bm25?: false,
      extractors: [:ex_ast],
      mirrors: [env("EXOGRAPH_MIRROR", "https://hex.pm")],
      registry_url: env("EXOGRAPH_REGISTRY_URL", env("EXOGRAPH_MIRROR", "https://hex.pm")),
      tarball_dir: System.get_env("EXOGRAPH_TARBALL_DIR"),
      repo: Exograph.DuckDBRepo
    ]

    result = Exograph.Hex.Corpus.index(opts)

    publish_file!(build.manifest_path, final_manifest_path)
    publish_file!(build.report_path, final_report_path)

    result
  end

  defp staged_build_paths(final_shard_dir) do
    build_id =
      DateTime.utc_now()
      |> Calendar.strftime("%Y%m%d%H%M%S")
      |> then(&"index-#{&1}-#{System.unique_integer([:positive])}")

    build_dir =
      final_shard_dir
      |> Path.dirname()
      |> Path.join("builds")
      |> Path.join(build_id)

    shard_dir = Path.join(build_dir, "shards")
    File.mkdir_p!(shard_dir)

    %{
      build_dir: build_dir,
      shard_dir: shard_dir,
      manifest_path: Path.join(build_dir, "hex-manifest.term"),
      report_path: Path.join(build_dir, "index-report.json")
    }
  end

  defp publish_file!(source, destination) do
    destination
    |> Path.dirname()
    |> File.mkdir_p!()

    temporary_destination = "#{destination}.tmp-#{System.unique_integer([:positive])}"
    File.cp!(source, temporary_destination)
    File.rename!(temporary_destination, destination)
  end

  defp env(name, default), do: System.get_env(name) || default

  defp env_integer(name, default) do
    case System.get_env(name) do
      nil -> default
      "" -> default
      value -> String.to_integer(value)
    end
  end
end
