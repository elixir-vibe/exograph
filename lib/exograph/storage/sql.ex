defmodule Exograph.Storage.SQL do
  @moduledoc """
  SQL helpers used by the DuckDB/QuackDB storage layer.
  """

  def bulk_insert_all(repo, source, entries, opts \\ []) do
    chunk_size = Keyword.get(opts, :chunk_size, 1_000)
    max_concurrency = Keyword.get_lazy(opts, :max_concurrency, fn -> repo_pool_size(repo) end)
    insert_opts = Keyword.drop(opts, [:chunk_size, :max_concurrency])

    entries
    |> Enum.chunk_every(chunk_size)
    |> insert_chunks(repo, source, insert_opts, max_concurrency)
  end

  def table(prefix, name), do: identifier(Exograph.Storage.Schema.table_name(prefix, name))

  def identifier(name), do: quote_identifier(name)

  def copy_integer_rows(_repo, _table, _columns, []), do: :ok

  def copy_integer_rows(repo, table, columns, rows) do
    table_name = source_table_name(table)
    column_names = Enum.map_join(columns, ", ", &quote_identifier/1)
    sql = "COPY #{quote_identifier(table_name)} (#{column_names}) FROM STDIN WITH (FORMAT csv)"

    repo.transaction(
      fn ->
        stream = Ecto.Adapters.SQL.stream(repo, sql, [], timeout: :infinity)

        rows
        |> Stream.map(&integer_csv_row(&1, columns))
        |> Enum.into(stream)
      end,
      timeout: :infinity
    )

    :ok
  end

  def query(repo, sql, params \\ []), do: Ecto.Adapters.SQL.query(repo, sql, params)

  defp source_table_name({table, _schema}), do: table
  defp source_table_name(table) when is_binary(table), do: table

  defp quote_identifier(identifier) when is_atom(identifier) do
    identifier |> Atom.to_string() |> quote_identifier()
  end

  defp quote_identifier(identifier) when is_binary(identifier) do
    ~s("#{String.replace(identifier, "\"", "\"\"")}")
  end

  defp integer_csv_row(row, columns) do
    columns
    |> Enum.map(fn column -> Map.fetch!(row, column) end)
    |> Enum.join(",")
    |> Kernel.<>("\n")
  end

  defp insert_chunks([], _repo, _source, _opts, _max_concurrency), do: :ok

  defp insert_chunks([chunk], repo, source, opts, _max_concurrency) do
    repo.insert_all(source, chunk, opts)
    :ok
  end

  defp insert_chunks(chunks, repo, source, opts, max_concurrency) do
    dynamic_repo = current_dynamic_repo(repo)

    chunks
    |> Task.async_stream(
      fn chunk ->
        with_dynamic_repo(repo, dynamic_repo, fn -> repo.insert_all(source, chunk, opts) end)
      end,
      max_concurrency: max_concurrency,
      ordered: false,
      timeout: :infinity
    )
    |> Enum.each(fn
      {:ok, _result} -> :ok
      {:exit, reason} -> exit(reason)
    end)
  end

  defp current_dynamic_repo(repo) do
    if function_exported?(repo, :get_dynamic_repo, 0), do: repo.get_dynamic_repo(), else: nil
  end

  defp with_dynamic_repo(_repo, nil, fun), do: fun.()

  defp with_dynamic_repo(repo, dynamic_repo, fun) do
    if function_exported?(repo, :put_dynamic_repo, 1) and
         function_exported?(repo, :get_dynamic_repo, 0) do
      previous = repo.get_dynamic_repo()
      repo.put_dynamic_repo(dynamic_repo)

      try do
        fun.()
      after
        repo.put_dynamic_repo(previous)
      end
    else
      fun.()
    end
  end

  defp repo_pool_size(repo) do
    repo.config()
    |> Keyword.get(:exograph_bulk_concurrency, 2)
    |> min(System.schedulers_online())
    |> max(1)
  end
end
