defmodule Exograph.Storage.SQL do
  @moduledoc """
  Identifier quoting helpers used at QuackDB helper boundaries.
  """

  def table(prefix, name), do: identifier(Exograph.Storage.Schema.table_name(prefix, name))

  def identifier(name), do: QuackDB.Type.quote_identifier(to_string(name))

  def bulk_insert_all(repo, source, entries, opts \\ []) do
    chunk_size = Keyword.get(opts, :chunk_size, 1_000)
    max_concurrency = Keyword.get_lazy(opts, :max_concurrency, fn -> repo_pool_size(repo) end)
    insert_opts = Keyword.drop(opts, [:chunk_size, :max_concurrency])

    entries
    |> Enum.chunk_every(chunk_size)
    |> insert_chunks(repo, source, insert_opts, max_concurrency)
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
    previous = repo.put_dynamic_repo(dynamic_repo)

    try do
      fun.()
    after
      repo.put_dynamic_repo(previous)
    end
  end

  defp repo_pool_size(repo) do
    repo.config()
    |> Keyword.get(:pool_size, System.schedulers_online())
    |> max(1)
  rescue
    ArgumentError -> System.schedulers_online()
  end
end
