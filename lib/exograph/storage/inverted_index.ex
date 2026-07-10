defmodule Exograph.Storage.InvertedIndex do
  @moduledoc """
  Ecto candidate retrieval for DuckDB/QuackDB indexes.

  Structural lookups use a normalized candidate table on DuckDB. Term strings
  are normalized to integer IDs in the terms table before querying.
  """

  import Ecto.Query
  import QuackDB.Ecto.Regex, only: [regexp_matches: 2]

  alias Exograph.{Hit, Package, PackageVersion}

  alias Exograph.Storage.{
    CallEdgeRecord,
    Config,
    FactQuery,
    FragmentRecord,
    Hydration,
    Schema,
    Scope
  }

  alias Exograph.StructuralQuery

  defstruct repo: nil, prefix: "exograph", package: nil, package_version: nil, bm25?: true

  @type t :: %__MODULE__{
          repo: module(),
          prefix: String.t(),
          package: Package.t() | nil,
          package_version: PackageVersion.t() | nil,
          bm25?: boolean()
        }

  def new(opts \\ []), do: {:ok, Config.store(__MODULE__, opts)}

  def add(%__MODULE__{} = index, fragments) when is_list(fragments) do
    {:ok, index}
  end

  def search(%__MODULE__{} = index, %StructuralQuery{} = query, opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)
    required = MapSet.to_list(query.required_terms)
    optional = MapSet.to_list(query.optional_terms)

    required_ids = resolve_term_ids(index, required)
    optional_ids = resolve_term_ids(index, optional)

    required_id_set = MapSet.new(required_ids)
    optional_id_set = MapSet.new(optional_ids)

    records =
      base_query(index)
      |> where_term_ids(index, required_ids, optional_ids)
      |> Scope.where_scope(opts)
      |> limit(^limit)
      |> with_file(index, include_source?(query))
      |> index.repo.all()

    hits = Enum.map(records, &hit(&1, query, required_id_set, optional_id_set))
    {:ok, hits}
  end

  def search_text(%__MODULE__{} = index, literal, opts \\ []) when is_binary(literal) do
    Exograph.DuckDB.TextSearch.search_file_field(index, literal, :source, opts)
  end

  def search_comments(%__MODULE__{} = index, literal, opts \\ []) when is_binary(literal) do
    Exograph.DuckDB.TextSearch.search_file_field(index, literal, :comments_text, opts)
  end

  def search_definitions(%__MODULE__{} = index, literal, opts \\ []) when is_binary(literal) do
    FactQuery.search(index, definitions_source(index), literal, opts)
  end

  def search_references(%__MODULE__{} = index, literal, opts \\ []) when is_binary(literal) do
    FactQuery.search(index, references_source(index), literal, opts)
  end

  def search_callers(%__MODULE__{} = index, callee, opts \\ []) when is_binary(callee) do
    search_call_edges(index, :callee_qualified_name, callee, opts)
  end

  def search_callees(%__MODULE__{} = index, caller, opts \\ []) when is_binary(caller) do
    search_call_edges(index, :caller_qualified_name, caller, opts)
  end

  defp search_call_edges(index, field, literal, opts) do
    limit = Keyword.get(opts, :limit, 50)
    skip = Keyword.get(opts, :skip, 0)

    records =
      from(edge in call_edges_source(index),
        where: field(edge, ^field) == ^literal or ilike(field(edge, ^field), ^"%#{literal}%"),
        order_by: [asc: edge.file_id, asc: edge.line, asc: edge.id],
        offset: ^skip,
        limit: ^limit
      )
      |> Scope.where_scope(opts)
      |> index.repo.all()

    {:ok, Enum.map(records, &CallEdgeRecord.to_call_edge/1)}
  end

  def resolve_term_ids(_index, []), do: []

  def resolve_term_ids(index, terms) when is_list(terms) do
    from(t in Schema.terms_source(index.prefix), where: t.term in ^terms, select: t.id)
    |> index.repo.all(timeout: :infinity)
  rescue
    QuackDB.Error -> []
  end

  defp include_source?(%StructuralQuery{verifier: {:selector, _selector}} = query),
    do: StructuralQuery.requires_source?(query)

  defp include_source?(_query), do: true

  def search_text_regex(%__MODULE__{} = index, %Regex{source: pattern}, opts) do
    limit = Keyword.get(opts, :limit, 50)
    skip = Keyword.get(opts, :skip, 0)
    files = files_source(index)
    versions = package_versions_source(index)

    query =
      from(fragment in {source(index), FragmentRecord},
        join: file in ^files,
        on: file.id == fragment.file_id,
        left_join: version in ^versions,
        on: version.id == fragment.package_version_id,
        where: regexp_matches(file.source, ^pattern),
        order_by: [asc: file.path, asc: fragment.line],
        offset: ^skip,
        limit: ^limit,
        select: {fragment, file.source, file.path, version.version, file.ast}
      )
      |> Scope.where_scope(opts)

    hits =
      index.repo.all(query, timeout: 30_000)
      |> Enum.map(fn {record, source, path, package_version, file_ast} ->
        Hit.new(
          fragment: Hydration.fragment(record, source, path, package_version, nil, file_ast),
          score: 1.0
        )
      end)

    {:ok, hits}
  end

  defp with_file(queryable, index, true) do
    from(fragment in queryable,
      left_join: file in ^files_source(index),
      on: file.id == fragment.file_id,
      left_join: version in ^package_versions_source(index),
      on: version.id == fragment.package_version_id,
      select: {fragment, file.source, file.path, version.version, file.ast}
    )
  end

  defp with_file(queryable, index, false) do
    from(fragment in queryable,
      left_join: file in ^files_source(index),
      on: file.id == fragment.file_id,
      left_join: version in ^package_versions_source(index),
      on: version.id == fragment.package_version_id,
      select: {fragment, nil, file.path, version.version, file.ast}
    )
  end

  defp base_query(index) do
    from(fragment in {source(index), FragmentRecord},
      order_by: [desc: fragment.mass, asc: fragment.file_id, asc: fragment.line]
    )
  end

  defp where_term_ids(queryable, _index, [], []), do: queryable

  defp where_term_ids(queryable, index, required_ids, []) when required_ids != [] do
    join_required_term_candidates(queryable, index, required_ids)
  end

  defp where_term_ids(queryable, index, [], optional_ids) when optional_ids != [] do
    candidates = any_term_candidates(index, optional_ids)

    join(queryable, :inner, [fragment], candidate in subquery(candidates),
      on: candidate.fragment_id == fragment.id
    )
  end

  defp where_term_ids(queryable, index, required_ids, _optional_ids) do
    join_required_term_candidates(queryable, index, required_ids)
  end

  defp join_required_term_candidates(queryable, index, required_ids) do
    candidates = required_term_candidates(index, required_ids)

    join(queryable, :inner, [fragment], candidate in subquery(candidates),
      on: candidate.fragment_id == fragment.id
    )
  end

  defp required_term_candidates(index, [first_id | rest_ids]) do
    source = Schema.fragment_terms_source(index.prefix)

    query =
      from(term in source,
        as: :term,
        where: term.term_id == ^first_id,
        select: term.fragment_id
      )

    Enum.reduce(rest_ids, query, fn term_id, query ->
      join(query, :inner, [term, ...], next_term in ^source,
        on: next_term.fragment_id == term.fragment_id and next_term.term_id == ^term_id
      )
    end)
  end

  defp any_term_candidates(index, ids) do
    from(term in Schema.fragment_terms_source(index.prefix),
      where: term.term_id in ^ids,
      distinct: term.fragment_id,
      select: term.fragment_id
    )
  end

  defp hit(
         {%FragmentRecord{} = record, source, path, package_version, file_ast},
         _query,
         required_id_set,
         optional_id_set
       ) do
    fragment = Hydration.fragment(record, source, path, package_version, nil, file_ast)
    matched_terms = MapSet.union(required_id_set, optional_id_set)

    Hit.new(
      fragment: fragment,
      score: MapSet.size(required_id_set) * 10 + MapSet.size(optional_id_set),
      matched_terms: MapSet.to_list(matched_terms)
    )
  end

  defp files_source(index), do: Schema.files_source(index.prefix)
  defp package_versions_source(index), do: Schema.package_versions_source(index.prefix)
  defp definitions_source(index), do: Schema.definitions_source(index.prefix)
  defp references_source(index), do: Schema.references_source(index.prefix)
  defp call_edges_source(index), do: Schema.call_edges_source(index.prefix)
  defp source(index), do: Schema.fragments_source(index.prefix)
end
