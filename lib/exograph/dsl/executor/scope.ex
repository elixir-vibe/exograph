defmodule Exograph.DSL.Executor.Scope do
  @moduledoc false

  import Ecto.Query

  alias Exograph.DSL.Compiler
  alias Exograph.Storage.{InvertedIndex, Options}

  @doc false
  def where_fragment_scope(queryable, opts) do
    package_id = Keyword.get(opts, :package_id)

    package_version_id =
      Keyword.get(opts, :package_version_id) || Keyword.get(opts, :package_version)

    queryable
    |> maybe_where_fragment_package(package_id)
    |> maybe_where_fragment_package_version(package_version_id)
  end

  @doc false
  def maybe_where_fragment_package(queryable, nil), do: queryable

  def maybe_where_fragment_package(queryable, package_id),
    do: where(queryable, [fragment], fragment.package_id == ^package_id)

  @doc false
  def maybe_where_fragment_package_version(queryable, nil), do: queryable

  def maybe_where_fragment_package_version(queryable, package_version_id),
    do: where(queryable, [fragment], fragment.package_version_id == ^package_version_id)

  @doc false
  def where_fragment_scope_second(queryable, opts) do
    package_id = Keyword.get(opts, :package_id)

    package_version_id =
      Keyword.get(opts, :package_version_id) || Keyword.get(opts, :package_version)

    queryable
    |> maybe_where_second_package(package_id)
    |> maybe_where_second_package_version(package_version_id)
  end

  @doc false
  def maybe_where_second_package(queryable, nil), do: queryable

  def maybe_where_second_package(queryable, package_id),
    do: where(queryable, [_first, fragment], fragment.package_id == ^package_id)

  @doc false
  def maybe_where_second_package_version(queryable, nil), do: queryable

  def maybe_where_second_package_version(queryable, package_version_id),
    do: where(queryable, [_first, fragment], fragment.package_version_id == ^package_version_id)

  @doc false
  def where_scope(queryable, opts) do
    package_id = Keyword.get(opts, :package_id)

    package_version_id =
      Keyword.get(opts, :package_version_id) || Keyword.get(opts, :package_version)

    queryable
    |> maybe_where_package(package_id)
    |> maybe_where_package_version(package_version_id)
  end

  @doc false
  def maybe_where_package(queryable, nil), do: queryable

  def maybe_where_package(queryable, package_id),
    do: where(queryable, [row], row.package_id == ^package_id)

  @doc false
  def maybe_where_package_version(queryable, nil), do: queryable

  def maybe_where_package_version(queryable, package_version_id),
    do: where(queryable, [row], row.package_version_id == ^package_version_id)

  @doc false
  def where_fragment_text_contains(queryable, plan) do
    plan.query
    |> Compiler.text_contains_patterns()
    |> Enum.reduce(queryable, fn pattern, query ->
      like = "%#{escape_like(pattern)}%"
      where(query, [_fragment, file, _version], ilike(file.source, ^like))
    end)
  end

  @doc false
  def where_fragment_text_contains_third(queryable, plan) do
    plan.query
    |> Compiler.text_contains_patterns()
    |> Enum.reduce(queryable, fn pattern, query ->
      like = "%#{escape_like(pattern)}%"
      where(query, [_first, _fragment, file], ilike(file.source, ^like))
    end)
  end

  @doc false
  def where_fragment_text_contains_fourth(queryable, plan) do
    plan.query
    |> Compiler.text_contains_patterns()
    |> Enum.reduce(queryable, fn pattern, query ->
      like = "%#{escape_like(pattern)}%"
      where(query, [_fragment, _joined, file], ilike(file.source, ^like))
    end)
  end

  defp escape_like(value), do: value |> String.replace("%", "\\%") |> String.replace("_", "\\_")

  @doc false
  def where_structural_terms(queryable, index, plan) do
    case resolve_structural_term_ids(index, plan) do
      :no_required_terms -> queryable
      :missing_required_term -> where(queryable, false)
      {:ok, ids} -> where_fragment_term_ids(queryable, index, ids)
    end
  end

  @doc false
  def where_structural_terms_second(queryable, index, plan) do
    case resolve_structural_term_ids(index, plan) do
      :no_required_terms -> queryable
      :missing_required_term -> where(queryable, false)
      {:ok, ids} -> where_second_fragment_term_ids(queryable, index, ids)
    end
  end

  @doc false
  def where_fragment_term_ids(queryable, _index, []), do: queryable

  def where_fragment_term_ids(queryable, index, ids) do
    candidates = duckdb_term_candidates(index, ids)

    join(queryable, :inner, [fragment], candidate in subquery(candidates),
      on: candidate.fragment_id == fragment.id
    )
  end

  @doc false
  def where_second_fragment_term_ids(queryable, _index, []), do: queryable

  def where_second_fragment_term_ids(queryable, index, ids) do
    candidates = duckdb_term_candidates(index, ids)

    join(queryable, :inner, [_first, fragment], candidate in subquery(candidates),
      on: candidate.fragment_id == fragment.id
    )
  end

  defp duckdb_term_candidates(index, ids) do
    required_count = length(ids)

    from(term in Options.fragment_terms_source(index.inverted.prefix),
      where: term.term_id in ^ids,
      group_by: term.fragment_id,
      having: count(term.term_id, :distinct) == ^required_count,
      select: term.fragment_id
    )
  end

  defp resolve_structural_term_ids(index, plan) do
    required_terms = Compiler.required_terms(plan.query)

    if required_terms == [] do
      :no_required_terms
    else
      ids = InvertedIndex.resolve_term_ids(index.inverted, required_terms)

      if ids == [] do
        :missing_required_term
      else
        {:ok, ids}
      end
    end
  end
end
