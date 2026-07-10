defmodule Exograph.DSL.Executor.JoinBuilder do
  @moduledoc false

  import Ecto.Query

  alias Exograph.DSL.{Compiler, JoinSemantics, Sources}
  alias Exograph.DSL.Plan
  alias Exograph.Storage.{FragmentRecord, Schema}

  @function_fragment_kinds JoinSemantics.function_fragment_kinds()

  def build(index, %Plan{source: :fragment, joins: joins} = plan, opts)
      when length(joins) in 2..3 do
    root = plan.binding
    files_source = Schema.files_source(index.inverted.prefix)
    versions_source = Schema.package_versions_source(index.inverted.prefix)
    packages_source = Schema.packages_source(index.inverted.prefix)
    fragments_source = Schema.fragments_source(index.inverted.prefix)

    query =
      from(fragment in {fragments_source, FragmentRecord},
        as: ^root,
        left_join: file in ^files_source,
        as: :file,
        on: file.id == fragment.file_id,
        left_join: version in ^versions_source,
        as: :version,
        on: version.id == fragment.package_version_id,
        left_join: package in ^packages_source,
        as: :package,
        on: package.id == version.package_id,
        where: fragment.kind in ^@function_fragment_kinds,
        distinct: fragment.id,
        order_by: [asc: file.path, asc: fragment.line, asc: fragment.id],
        limit: ^Keyword.get(opts, :candidate_limit, 50),
        select: %{
          fragment: fragment,
          source: file.source,
          path: file.path,
          ast: file.ast,
          package_version: version.version,
          package: package.name
        }
      )
      |> add_joins(index, root, joins)
      |> where_predicates(plan)
      |> where_call_definition_pair(joins)
      |> where_scope(root, opts)
      |> where_text_contains(plan)
      |> where_structural_terms(index, plan, root)

    select_join_ids(query, joins)
  end

  defp select_join_ids(query, [first, second]) do
    first_binding = first.binding
    second_binding = second.binding

    select_merge(query, [], %{
      first_join_id: field(as(^first_binding), :id),
      second_join_id: field(as(^second_binding), :id)
    })
  end

  defp select_join_ids(query, [first, second, third]) do
    first_binding = first.binding
    second_binding = second.binding
    third_binding = third.binding

    select_merge(query, [], %{
      first_join_id: field(as(^first_binding), :id),
      second_join_id: field(as(^second_binding), :id),
      third_join_id: field(as(^third_binding), :id)
    })
  end

  defp add_joins(query, index, root, joins) do
    Enum.reduce(joins, query, fn join, query ->
      source = Sources.join_source(join.assoc, index.inverted.prefix)

      join(query, :inner, [], fact in ^source,
        as: ^join.binding,
        on:
          fact.file_id == field(as(^root), :file_id) and fact.line >= field(as(^root), :line) and
            (is_nil(field(as(^root), :end_line)) or fact.line <= field(as(^root), :end_line))
      )
    end)
  end

  defp where_predicates(query, %Plan{} = plan) do
    plan.predicates_by_binding
    |> Map.values()
    |> List.flatten()
    |> Enum.reduce(query, fn
      {:structural, _binding, _pattern}, query -> query
      {:contains, _binding, _pattern}, query -> query
      predicate, query -> where(query, [], ^predicate_dynamic(predicate))
    end)
  end

  defp predicate_dynamic({:eq, binding, field, value}),
    do: dynamic([], field(as(^binding), ^field) == ^value)

  defp predicate_dynamic({:in, binding, field, values}),
    do: dynamic([], field(as(^binding), ^field) in ^values)

  defp predicate_dynamic({:prefix_search, binding, field, value}),
    do: dynamic([], ilike(field(as(^binding), ^field), ^"#{value}%"))

  defp predicate_dynamic({:cmp, binding, field, operator, value}) do
    case operator do
      :> -> dynamic([], field(as(^binding), ^field) > ^value)
      :< -> dynamic([], field(as(^binding), ^field) < ^value)
      :>= -> dynamic([], field(as(^binding), ^field) >= ^value)
      :<= -> dynamic([], field(as(^binding), ^field) <= ^value)
    end
  end

  defp where_call_definition_pair(query, joins) do
    definition = Enum.find(joins, &(&1.assoc == :definitions))
    call = Enum.find(joins, &(&1.assoc == :calls))

    if definition && call do
      definition_binding = definition.binding
      call_binding = call.binding

      where(
        query,
        [],
        field(as(^call_binding), :caller_qualified_name) ==
          field(as(^definition_binding), :qualified_name)
      )
    else
      query
    end
  end

  defp where_scope(query, root, opts) do
    query
    |> maybe_where(root, :package_id, Keyword.get(opts, :package_id))
    |> maybe_where(
      root,
      :package_version_id,
      Keyword.get(opts, :package_version_id) || Keyword.get(opts, :package_version)
    )
  end

  defp maybe_where(query, _root, _field, nil), do: query

  defp maybe_where(query, root, field, value),
    do: where(query, [], field(as(^root), ^field) == ^value)

  defp where_text_contains(query, plan) do
    Enum.reduce(Compiler.text_contains_patterns(plan.query), query, fn text, query ->
      like = "%#{String.replace(text, "%", "\\%") |> String.replace("_", "\\_")}%"
      where(query, [], ilike(field(as(:file), :source), ^like))
    end)
  end

  defp where_structural_terms(query, index, plan, root) do
    case Compiler.required_terms(plan.query) do
      [] ->
        query

      terms ->
        ids = Exograph.Storage.InvertedIndex.resolve_term_ids(index.inverted, terms)

        if ids == [] do
          where(query, false)
        else
          candidates = term_candidates(index, ids)

          join(query, :inner, [], candidate in subquery(candidates),
            on: candidate.fragment_id == field(as(^root), :id)
          )
        end
    end
  end

  defp term_candidates(index, [first_id | rest_ids]) do
    source = Schema.fragment_terms_source(index.inverted.prefix)

    query = from(term in source, where: term.term_id == ^first_id, select: term.fragment_id)

    Enum.reduce(rest_ids, query, fn term_id, query ->
      join(query, :inner, [term, ...], next_term in ^source,
        on: next_term.fragment_id == term.fragment_id and next_term.term_id == ^term_id
      )
    end)
  end
end
