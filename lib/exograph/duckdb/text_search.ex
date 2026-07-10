defmodule Exograph.DuckDB.TextSearch do
  @moduledoc """
  File-level text search implemented with Ecto queries over DuckDB storage tables.
  """

  import Ecto.Query
  import QuackDB.Ecto.FTS, only: [match_bm25: 3]

  alias Exograph.Hit
  alias Exograph.Storage.{FragmentRecord, Hydration, Schema}

  def search_file_field(index, literal, field, opts) when field in [:source, :comments_text] do
    limit = Keyword.get(opts, :limit, 50)
    pattern = "%#{escape_like(literal)}%"

    query = search_query(index, literal, field, pattern, opts, limit)

    hits =
      query_hits(index, query, fn ->
        search_query(index, literal, field, pattern, Keyword.put(opts, :force_ilike, true), limit)
      end)

    {:ok, hits}
  end

  defp search_query(index, literal, field, pattern, opts, limit) do
    skip = Keyword.get(opts, :skip, 0)

    matched_files =
      index
      |> matched_files_query(literal, field, pattern, opts)
      |> offset(^skip)
      |> limit(^limit)

    first_fragment =
      from(fragment in {Schema.fragments_source(index.prefix), FragmentRecord},
        where: fragment.file_id == parent_as(:matched_file).id,
        order_by: [asc: fragment.line],
        limit: 1
      )

    from(file in subquery(matched_files),
      as: :matched_file,
      inner_lateral_join: fragment in subquery(first_fragment),
      on: true,
      left_join: package_version in ^Schema.package_versions_source(index.prefix),
      on: package_version.id == fragment.package_version_id,
      order_by: [desc: file.score, asc: file.path, asc: fragment.line],
      select: {fragment, file.source, file.path, package_version.version, file.ast}
    )
  end

  defp query_hits(index, query, fallback) do
    index.repo.all(query)
    |> Enum.map(fn {record, source, path, package_version, file_ast} ->
      Hit.new(
        fragment: Hydration.fragment(record, source, path, package_version, nil, file_ast),
        score: 1.0
      )
    end)
  rescue
    error in QuackDB.Error ->
      if bm25_unavailable?(error) do
        query_hits(index, fallback.(), fn -> reraise(error, __STACKTRACE__) end)
      else
        reraise(error, __STACKTRACE__)
      end
  end

  defp matched_files_query(index, literal, field, pattern, opts) do
    index
    |> base_matched_files_query(literal, field, pattern, opts)
    |> maybe_where_package_version(opts)
  end

  defp base_matched_files_query(index, literal, field, pattern, opts) do
    if Keyword.get(opts, :force_ilike, false) do
      ilike_matched_files_query(index, field, pattern)
    else
      maybe_bm25_matched_files_query(index, literal, field, pattern)
    end
  end

  defp maybe_bm25_matched_files_query(%{bm25?: true} = index, literal, field, pattern)
       when is_binary(literal) do
    if simple_fts_literal?(literal) do
      {files_table, _schema} = Schema.files_source(index.prefix)
      schema = QuackDB.FTS.schema_name("main.#{files_table}")

      from(file in Schema.files_source(index.prefix),
        where: match_bm25(^schema, file.id, ^literal) > 0,
        where: ilike(field(file, ^field), ^pattern),
        order_by: [desc: match_bm25(^schema, file.id, ^literal), asc: file.path],
        select: %{
          id: file.id,
          source: file.source,
          path: file.path,
          ast: file.ast,
          score: match_bm25(^schema, file.id, ^literal)
        }
      )
    else
      ilike_matched_files_query(index, field, pattern)
    end
  rescue
    _ in [QuackDB.Error, Ecto.QueryError] -> ilike_matched_files_query(index, field, pattern)
  end

  defp maybe_bm25_matched_files_query(index, _literal, field, pattern) do
    ilike_matched_files_query(index, field, pattern)
  end

  defp ilike_matched_files_query(index, field, pattern) do
    from(file in Schema.files_source(index.prefix),
      where: ilike(field(file, ^field), ^pattern),
      order_by: [asc: file.path],
      select: %{
        id: file.id,
        source: file.source,
        path: file.path,
        ast: file.ast,
        score: type(^0.0, :float)
      }
    )
  end

  defp maybe_where_package_version(query, opts) do
    case Keyword.get(opts, :package_version_id) || Keyword.get(opts, :package_version) do
      id when is_integer(id) -> where(query, [file], file.package_version_id == ^id)
      _ -> query
    end
  end

  defp bm25_unavailable?(%{message: message}) when is_binary(message) do
    String.contains?(message, "match_bm25") and String.contains?(message, "does not exist")
  end

  defp simple_fts_literal?(literal), do: String.match?(literal, ~r/^\w+$/u)

  defp escape_like(value), do: value |> String.replace("%", "\\%") |> String.replace("_", "\\_")
end
