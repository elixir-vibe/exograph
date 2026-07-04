defmodule Mix.Exograph.DuckDBOptions do
  @moduledoc false

  def opts(opts) do
    [
      repo: duckdb_repo!(opts),
      prefix: Keyword.get(opts, :prefix, "exograph"),
      migrate?: Keyword.get(opts, :migrate, false),
      bm25?: !Keyword.get(opts, :no_bm25, false),
      duckdb_threads: Keyword.get(opts, :duckdb_threads)
    ]
  end

  defp duckdb_repo!(opts) do
    case Keyword.get(opts, :repo) do
      nil -> start_default_duckdb_repo!(opts)
      repo -> module!(repo)
    end
  end

  defp start_default_duckdb_repo!(opts) do
    Application.ensure_all_started(:ecto_sql)
    Application.ensure_all_started(:quackdb)

    {uri, token} = duckdb_connection(opts)

    Application.put_env(:exograph, Exograph.DuckDBRepo,
      uri: uri,
      token: token,
      pool_size: 5,
      queue_target: Keyword.get(opts, :duckdb_queue_target, 60_000),
      queue_interval: Keyword.get(opts, :duckdb_queue_interval, 120_000),
      telemetry_prefix: [:quackdb],
      log: false,
      timeout: 120_000
    )

    case Process.whereis(Exograph.DuckDBRepo) do
      nil -> {:ok, _pid} = Exograph.DuckDBRepo.start_link()
      _pid -> :ok
    end

    Exograph.DuckDBRepo
  end

  defp duckdb_connection(opts) do
    case Keyword.get(opts, :quackdb_uri) || System.get_env("QUACKDB_URI") ||
           System.get_env("QUACKDB_TEST_URI") do
      nil ->
        token = duckdb_token(opts)
        endpoint = "quack:127.0.0.1:#{free_tcp_port!()}"

        {:ok, server} =
          QuackDB.Server.start_link(
            duckdb: :managed,
            database: Keyword.get(opts, :duckdb_database, default_duckdb_database(opts)),
            endpoint: endpoint,
            token: token,
            settings: duckdb_settings(Keyword.get(opts, :duckdb_threads))
          )

        {QuackDB.Server.uri(server), token}

      uri ->
        {uri, duckdb_token(opts)}
    end
  end

  defp default_duckdb_database(opts), do: "#{Keyword.get(opts, :prefix, "exograph")}.duckdb"

  @doc false
  def duckdb_token(opts) do
    Keyword.get(opts, :quackdb_token) || System.get_env("QUACKDB_TOKEN") ||
      System.get_env("QUACKDB_TEST_TOKEN") || "exograph"
  end

  @doc false
  def duckdb_settings(nil), do: [threads: System.schedulers_online()]
  def duckdb_settings(threads), do: [threads: threads]

  @doc false
  def free_tcp_port! do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(socket)
    :ok = :gen_tcp.close(socket)
    port
  end

  defp module!(name) do
    name
    |> String.split(".")
    |> Module.concat()
  end
end
