defmodule Exograph.DuckDBShards do
  @moduledoc false

  defmodule Manifest do
    @moduledoc false

    defstruct version: 1,
              backend: :duckdb,
              shard_count: 0,
              prefix: nil,
              shards: []
  end

  defmodule Shard do
    @moduledoc false

    defstruct id: nil,
              repo: nil,
              dynamic_repo: nil,
              prefix: nil,
              database: nil,
              uri: nil,
              token: nil,
              server: nil,
              packages: [],
              index: nil,
              entries: []
  end

  def start_managed(count, opts \\ []) when count > 0 do
    Application.ensure_all_started(:ecto_sql)
    Application.ensure_all_started(:quackdb)

    directory = Keyword.get_lazy(opts, :directory, &System.tmp_dir!/0)
    File.mkdir_p!(directory)

    prefix = Keyword.get(opts, :prefix, "exograph_shard")
    port_base = Keyword.get(opts, :port_base, 9_600)
    duckdb_threads = Keyword.get(opts, :duckdb_threads)
    duckdb_memory_limit = Keyword.get(opts, :duckdb_memory_limit)

    shards =
      Enum.map(0..(count - 1), fn index ->
        database = database_path(Keyword.get(opts, :database), directory, prefix, index)
        token = Keyword.get(opts, :token, "exograph-shard-#{System.unique_integer([:positive])}")
        endpoint = "quack:127.0.0.1:#{port_base + index}"

        {:ok, server} =
          QuackDB.Server.start_link(
            server_opts(opts,
              database: database,
              endpoint: endpoint,
              token: token,
              settings: duckdb_settings(duckdb_threads, duckdb_memory_limit)
            )
          )

        name = unique_repo_name()
        uri = QuackDB.Server.uri(server)
        dynamic_repo = start_repo!(name, uri, token, repo_opts(opts))

        %Shard{
          id: index,
          repo: Exograph.DuckDBRepo,
          dynamic_repo: dynamic_repo,
          prefix: "#{prefix}_#{index}",
          database: database,
          uri: uri,
          token: token,
          server: server
        }
      end)

    {:ok, shards}
  end

  def load_manifest(%Manifest{} = manifest), do: manifest

  def load_manifest(path) when is_binary(path) do
    path
    |> File.read!()
    |> :erlang.binary_to_term([:safe])
  end

  def open(manifest, opts \\ [])

  def open(%Manifest{} = manifest, opts) do
    port_base = Keyword.get(opts, :port_base, 9_700)
    duckdb_threads = Keyword.get(opts, :duckdb_threads)
    duckdb_memory_limit = Keyword.get(opts, :duckdb_memory_limit)

    opened =
      Enum.map(manifest.shards, fn %Shard{} = shard ->
        token = Keyword.get(opts, :token, "exograph-shard-#{System.unique_integer([:positive])}")
        endpoint = "quack:127.0.0.1:#{port_base + shard.id}"

        {:ok, server} =
          QuackDB.Server.start_link(
            server_opts(opts,
              database: shard.database,
              endpoint: endpoint,
              token: token,
              settings: duckdb_settings(duckdb_threads, duckdb_memory_limit)
            )
          )

        name = unique_repo_name()
        uri = QuackDB.Server.uri(server)
        dynamic_repo = start_repo!(name, uri, token, repo_opts(opts))

        %{
          shard
          | repo: Exograph.DuckDBRepo,
            dynamic_repo: dynamic_repo,
            uri: uri,
            token: token,
            server: server
        }
      end)

    {:ok, opened}
  end

  def open(path, opts) when is_binary(path), do: path |> load_manifest() |> open(opts)

  def stop(shards) when is_list(shards) do
    Enum.each(shards, &stop/1)
    :ok
  end

  def stop(%{dynamic_repo: dynamic_repo, server: server}) do
    stop_pid(dynamic_repo)
    stop_pid(server)
    :ok
  end

  def stop(_shard), do: :ok

  def with_repo(%{dynamic_repo: dynamic_repo}, fun) when is_function(fun, 0) do
    previous = Exograph.DuckDBRepo.get_dynamic_repo()
    Exograph.DuckDBRepo.put_dynamic_repo(dynamic_repo)

    try do
      fun.()
    after
      Exograph.DuckDBRepo.put_dynamic_repo(previous)
    end
  end

  def with_repo(_shard, fun) when is_function(fun, 0), do: fun.()

  def open_indexes(shards, opts \\ []) do
    Enum.map(shards, fn shard ->
      {:ok, index} =
        with_repo(shard, fn ->
          Exograph.index([],
            backend: :duckdb,
            repo: shard.repo,
            prefix: shard.prefix,
            migrate?: false,
            bm25?: Keyword.get(opts, :bm25?, true),
            duckdb_threads: Keyword.get(opts, :duckdb_threads)
          )
        end)

      Map.put(shard, :index, index)
    end)
  end

  def manifest(shards, opts \\ []) do
    %Manifest{
      shard_count: length(shards),
      prefix: Keyword.get(opts, :prefix),
      shards:
        Enum.map(shards, fn shard ->
          %Shard{
            id: shard.id,
            prefix: shard.prefix,
            database: shard.database,
            packages: Map.get(shard, :packages, [])
          }
        end)
    }
  end

  defp stop_pid(pid) when is_pid(pid) do
    if Process.alive?(pid) do
      Process.unlink(pid)
      ref = Process.monitor(pid)

      try do
        GenServer.stop(pid, :normal, 5_000)
      catch
        :exit, _reason -> Process.exit(pid, :shutdown)
      end

      receive do
        {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
      after
        5_000 ->
          Process.exit(pid, :kill)

          receive do
            {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
          after
            1_000 -> :ok
          end
      end
    end
  end

  defp stop_pid(_pid), do: :ok

  defp server_opts(opts, base) do
    base
    |> Keyword.put(:duckdb, Keyword.get(opts, :duckdb, :managed))
    |> put_optional(:recovery_mode, Keyword.get(opts, :recovery_mode))
  end

  defp put_optional(opts, _key, nil), do: opts
  defp put_optional(opts, key, value), do: Keyword.put(opts, key, value)

  defp database_path(nil, directory, prefix, index) do
    Path.join(directory, "#{prefix}_#{index}.duckdb")
  end

  defp database_path(paths, _directory, _prefix, index) when is_list(paths),
    do: Enum.at(paths, index)

  defp database_path(path, _directory, _prefix, _index) when is_binary(path), do: path

  defp duckdb_settings(threads, memory_limit) do
    [threads: threads || System.schedulers_online()]
    |> put_optional(:memory_limit, memory_limit)
  end

  defp unique_repo_name do
    :erlang.unique_integer([:positive])
    |> then(&:"exograph_duckdb_shard_#{&1}")
  end

  defp repo_opts(opts) do
    [
      pool_size: Keyword.get(opts, :pool_size, 1),
      queue_target: Keyword.get(opts, :queue_target, 60_000),
      queue_interval: Keyword.get(opts, :queue_interval, 120_000)
    ]
  end

  defp start_repo!(name, uri, token, opts) do
    config = [
      name: name,
      uri: uri,
      token: token,
      pool_size: Keyword.fetch!(opts, :pool_size),
      queue_target: Keyword.fetch!(opts, :queue_target),
      queue_interval: Keyword.fetch!(opts, :queue_interval),
      telemetry_prefix: [:quackdb],
      log: false,
      timeout: 120_000
    ]

    case Exograph.DuckDBRepo.start_link(config) do
      {:ok, pid} -> pid
      {:error, {:already_started, pid}} -> pid
    end
  end
end
