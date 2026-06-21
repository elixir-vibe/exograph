defmodule Exograph.Storage.Ecto.FactQuery do
  @moduledoc false

  import Ecto.Query

  alias Exograph.{DefinitionHit, ReferenceHit, Scope, Text}
  alias Exograph.Storage.Ecto.{FragmentRecord, Options}

  def search(index, table_source, literal, opts) do
    limit = Keyword.get(opts, :limit, 50)
    files_source = Options.files_source(index.prefix)
    versions_source = Options.package_versions_source(index.prefix)

    results =
      ilike_search(index, table_source, literal, opts, limit, files_source, versions_source)

    {:ok, Enum.map(results, &hit(&1, table_source))}
  end

  defp ilike_search(index, table_source, literal, opts, limit, files_source, versions_source) do
    query =
      from(fragment in {Options.fragments_source(index.prefix), FragmentRecord},
        join: fact in ^table_source,
        on: fact.fragment_id == fragment.id,
        left_join: file in ^files_source,
        on: file.id == fragment.file_id,
        left_join: version in ^versions_source,
        on: version.id == fragment.package_version_id,
        where: ilike(fact.qualified_name, ^"%#{escape_like(literal)}%"),
        order_by: [asc: fact.qualified_name, asc: fact.line],
        limit: ^limit,
        select: {fragment, nil, file.path, version.version, fact}
      )
      |> where_scope(opts)

    index.repo.all(query)
  end

  def where_scope(queryable, opts) do
    package_id = Keyword.get(opts, :package_id)

    package_version_id =
      Keyword.get(opts, :package_version_id) || Keyword.get(opts, :package_version)

    queryable
    |> maybe_where_package(package_id)
    |> maybe_where_package_version(package_version_id)
  end

  def fallback_filter(fragments, literal, opts, mapper) do
    literal = String.downcase(literal)

    fragments
    |> Enum.filter(fn fragment ->
      Scope.fragment?(fragment, opts) and Enum.any?(mapper.(fragment), &contains?(&1, literal))
    end)
  end

  defp hit(
         {record, source, path, package_version, fact},
         {_table, Exograph.Storage.Ecto.DefinitionRecord}
       ) do
    DefinitionHit.new(
      definition: Exograph.Storage.Ecto.DefinitionRecord.to_definition(fact),
      fragment: Options.hydrate_fragment(record, source, path, package_version),
      score: 1.0
    )
  end

  defp hit(
         {record, source, path, package_version, fact},
         {_table, Exograph.Storage.Ecto.ReferenceRecord}
       ) do
    ReferenceHit.new(
      reference: Exograph.Storage.Ecto.ReferenceRecord.to_reference(fact),
      fragment: Options.hydrate_fragment(record, source, path, package_version),
      score: 1.0
    )
  end

  defp maybe_where_package(queryable, nil), do: queryable

  defp maybe_where_package(queryable, package_id),
    do: where(queryable, [_fragment, fact], fact.package_id == ^package_id)

  defp maybe_where_package_version(queryable, nil), do: queryable

  defp maybe_where_package_version(queryable, package_version_id),
    do: where(queryable, [_fragment, fact], fact.package_version_id == ^package_version_id)

  defp contains?(value, literal), do: Text.literal_match?(to_string(value), literal)

  defp escape_like(str), do: str |> String.replace("%", "\\%") |> String.replace("_", "\\_")
end
