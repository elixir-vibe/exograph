defmodule Exograph.Web.Runtime do
  @moduledoc false

  use Supervisor

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    port = Keyword.fetch!(opts, :port)
    prefix = Keyword.fetch!(opts, :prefix)
    backend = Keyword.fetch!(opts, :backend)

    Application.ensure_all_started(:phoenix)
    Application.ensure_all_started(:phoenix_live_view)

    {index, index_opts} = open_index!(backend, opts)

    Application.put_env(:exograph, :web_index, index)
    Application.put_env(:exograph, :web_repo, Keyword.fetch!(index_opts, :repo))
    Application.put_env(:exograph, :web_prefix, prefix)
    put_optional_env(:web_public_url, Keyword.get(opts, :public_url))
    put_optional_env(:web_site_name, Keyword.get(opts, :site_name))

    Exograph.Web.Server.put_endpoint_config(port)

    children =
      [
        {Phoenix.PubSub, name: Exograph.Web.PubSub},
        Exograph.Web.Endpoint
      ] ++ rate_limiter_children()

    Supervisor.init(children, strategy: :one_for_one)
  end

  def env_options do
    [
      backend: env("EXOGRAPH_BACKEND", "duckdb"),
      prefix: env("EXOGRAPH_PREFIX", "hex"),
      port: env_integer("EXOGRAPH_PORT", 4_200),
      database_url: System.get_env("EXOGRAPH_DATABASE_URL"),
      quackdb_uri: System.get_env("QUACKDB_URI") || System.get_env("QUACKDB_TEST_URI"),
      quackdb_token: System.get_env("QUACKDB_TOKEN") || System.get_env("QUACKDB_TEST_TOKEN"),
      duckdb_database: System.get_env("EXOGRAPH_DUCKDB_DATABASE"),
      manifest_path: System.get_env("EXOGRAPH_MANIFEST"),
      duckdb_threads: env_integer("EXOGRAPH_DUCKDB_THREADS", nil),
      duckdb_memory_limit: System.get_env("EXOGRAPH_DUCKDB_MEMORY_LIMIT"),
      shard_pool_size: env_integer("EXOGRAPH_SHARD_POOL_SIZE", 1),
      shard_port_base: env_integer("EXOGRAPH_SHARD_PORT_BASE", 9_700),
      public_url: System.get_env("EXOGRAPH_PUBLIC_URL"),
      site_name: System.get_env("EXOGRAPH_SITE_NAME")
    ]
  end

  def open_index!("duckdb", opts) do
    case Keyword.get(opts, :manifest_path) do
      path when is_binary(path) and path != "" ->
        {:ok, shards} =
          Exograph.DuckDBShards.open(path,
            duckdb_threads: opts[:duckdb_threads],
            duckdb_memory_limit: opts[:duckdb_memory_limit],
            pool_size: opts[:shard_pool_size] || 1,
            port_base: opts[:shard_port_base] || 9_700
          )

        shard_indexes = Exograph.DuckDBShards.open_indexes(shards, bm25?: true)
        manifest = Exograph.DuckDBShards.load_manifest(path)
        index = Exograph.ShardedIndex.new(shard_indexes, manifest: manifest)
        {index, [repo: Exograph.DuckDBRepo, prefix: opts[:prefix]]}

      _missing ->
        index_opts = duckdb_backend_opts(opts)

        {:ok, index} =
          Exograph.index(
            [],
            Keyword.merge([backend: :duckdb, migrate?: false, bm25?: true], index_opts)
          )

        {index, index_opts}
    end
  end

  def open_index!("postgres", opts) do
    repo_opts = [url: opts[:database_url], pool_size: 5, ssl: false, log: false, timeout: 120_000]
    repo_opts = Enum.reject(repo_opts, fn {_key, value} -> is_nil(value) end)
    {:ok, _pid} = Exograph.Web.Repo.start_link(repo_opts)
    index_opts = [repo: Exograph.Web.Repo, prefix: opts[:prefix], bm25?: true]

    {:ok, index} =
      Exograph.index(
        [],
        Keyword.merge([backend: :postgres, migrate?: false, bm25?: true], index_opts)
      )

    {index, index_opts}
  end

  def open_index!(other, _opts) do
    raise ArgumentError, "unknown Exograph backend #{inspect(other)}"
  end

  defp duckdb_backend_opts(opts) do
    [
      repo: Exograph.DuckDBRepo,
      prefix: opts[:prefix],
      quackdb_uri: opts[:quackdb_uri],
      quackdb_token: opts[:quackdb_token],
      database: opts[:duckdb_database],
      duckdb_threads: opts[:duckdb_threads],
      duckdb_memory_limit: opts[:duckdb_memory_limit]
    ]
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp put_optional_env(_key, nil), do: :ok
  defp put_optional_env(_key, ""), do: :ok
  defp put_optional_env(key, value), do: Application.put_env(:exograph, key, value)

  defp rate_limiter_children do
    if Code.ensure_loaded?(Hammer), do: [Exograph.Web.RateLimiter], else: []
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
