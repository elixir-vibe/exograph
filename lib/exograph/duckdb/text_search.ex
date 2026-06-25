defmodule Exograph.DuckDB.TextSearch do
  @moduledoc """
  File-level text search implemented with Ecto queries over DuckDB storage tables.
  """

  import Ecto.Query

  alias Exograph.Hit
  alias Exograph.Storage.{FragmentRecord, Hydration, Schema}

  def search_file_field(index, literal, field, opts) when field in [:source, :comments_text] do
    limit = Keyword.get(opts, :limit, 50)
    pattern = "%#{escape_like(literal)}%"

    matched_files =
      index
      |> matched_files_query(field, pattern, opts)
      |> limit(^limit)

    first_fragment =
      from(fragment in {Schema.fragments_source(index.prefix), FragmentRecord},
        where: fragment.file_id == parent_as(:matched_file).id,
        order_by: [asc: fragment.line],
        limit: 1
      )

    query =
      from(file in subquery(matched_files),
        as: :matched_file,
        inner_lateral_join: fragment in subquery(first_fragment),
        on: true,
        left_join: package_version in ^Schema.package_versions_source(index.prefix),
        on: package_version.id == fragment.package_version_id,
        order_by: [asc: file.path, asc: fragment.line],
        select: {fragment, file.source, file.path, package_version.version}
      )

    hits =
      index.repo.all(query)
      |> Enum.map(fn {record, source, path, package_version} ->
        Hit.new(
          fragment: Hydration.fragment(record, source, path, package_version),
          score: 1.0
        )
      end)

    {:ok, hits}
  end

  defp matched_files_query(index, field, pattern, opts) do
    query =
      from(file in Schema.files_source(index.prefix),
        where: ilike(field(file, ^field), ^pattern),
        order_by: [asc: file.path],
        select: %{id: file.id, source: file.source, path: file.path}
      )

    case Keyword.get(opts, :package_version_id) || Keyword.get(opts, :package_version) do
      id when is_integer(id) -> where(query, [file], file.package_version_id == ^id)
      _ -> query
    end
  end

  defp escape_like(value), do: value |> String.replace("%", "\\%") |> String.replace("_", "\\_")
end
