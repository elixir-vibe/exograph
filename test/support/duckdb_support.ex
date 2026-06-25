defmodule Exograph.DuckDBSupport do
  @moduledoc """
  Test helpers for starting temporary QuackDB-backed repos and cleaning Exograph schemas.
  """

  def start_repo! do
    Application.ensure_all_started(:ecto_sql)
    Application.ensure_all_started(:quackdb)

    Application.put_env(:exograph, Exograph.DuckDBRepo,
      uri: System.fetch_env!("QUACKDB_TEST_URI"),
      token: System.get_env("QUACKDB_TEST_TOKEN", ""),
      pool_size: 1,
      log: false
    )

    ExUnit.Callbacks.start_supervised!(Exograph.DuckDBRepo)
  end

  def start_managed_repo!(opts \\ []) do
    Application.ensure_all_started(:ecto_sql)
    Application.ensure_all_started(:quackdb)

    database =
      Keyword.get_lazy(opts, :database, fn ->
        Path.join(
          System.tmp_dir!(),
          "exograph-duckdb-#{System.unique_integer([:positive])}.duckdb"
        )
      end)

    token = Keyword.get(opts, :token, "test")
    File.rm_rf(database)

    endpoint =
      Keyword.get_lazy(opts, :endpoint, fn ->
        "quack:127.0.0.1:#{Mix.Exograph.DuckDBOptions.free_tcp_port!()}"
      end)

    server_opts =
      [
        duckdb: :managed,
        database: database,
        endpoint: endpoint,
        token: token,
        settings: [threads: Keyword.get(opts, :duckdb_threads, 1)]
      ]

    server = ExUnit.Callbacks.start_supervised!({QuackDB.Server, server_opts})

    Application.put_env(:exograph, Exograph.DuckDBRepo,
      uri: QuackDB.Server.uri(server),
      token: token,
      pool_size: 1,
      log: Keyword.get(opts, :log, false),
      timeout: Keyword.get(opts, :timeout, 120_000)
    )

    ExUnit.Callbacks.start_supervised!(Exograph.DuckDBRepo)
    database
  end

  def opts(prefix, opts \\ []) do
    Keyword.merge(
      [repo: Exograph.DuckDBRepo, prefix: prefix, migrate?: true],
      opts
    )
  end

  def drop_prefix(prefix) do
    if Process.whereis(Exograph.DuckDBRepo) do
      Exograph.Storage.Schema.tables()
      |> Enum.reverse()
      |> Enum.each(fn table ->
        Exograph.DuckDBRepo.query!(
          ["DROP TABLE IF EXISTS ", Exograph.Storage.SQL.table(prefix, table.name)],
          []
        )
      end)
    end
  end
end
