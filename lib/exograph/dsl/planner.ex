defmodule Exograph.DSL.Planner do
  @moduledoc false

  alias Exograph.DSL.Plan
  alias Exograph.DSL.Plan.Join
  alias Exograph.Query
  alias Exograph.Query.Predicate

  @assoc_sources %{
    definitions: :definition,
    references: :reference,
    calls: :call_edge
  }

  @source_assocs %{
    package: [],
    package_version: [],
    file: [],
    fragment: [:definitions, :references, :calls],
    definition: [:calls],
    reference: [],
    call_edge: []
  }

  @spec plan(Query.t()) :: Plan.t()
  def plan(%Query{} = query) do
    query = Query.validate!(query)
    joins = Enum.with_index(query.joins, 1) |> Enum.map(&join/1)
    predicates = Enum.map(query.predicates, &Predicate.to_internal/1)
    select = internal_select(query.select)
    internal_query = %{query | predicates: predicates, select: select}

    %Plan{
      query: internal_query,
      source: query.source,
      binding: query.binding,
      joins: joins,
      predicates_by_binding: Enum.group_by(predicates, &predicate_binding/1),
      structural_predicates: Enum.filter(predicates, &structural_predicate?/1),
      select: select
    }
    |> validate!()
  end

  defp join({%Exograph.Query.Join{} = query_join, position}) do
    %Join{
      parent: query_join.parent,
      binding: query_join.binding,
      assoc: query_join.association,
      source: assoc_source!(query_join.association),
      position: position
    }
  end

  defp join({join, _position}) do
    raise ArgumentError, "unsupported Exograph join: #{inspect(join)}"
  end

  defp assoc_source!(assoc) do
    Map.fetch!(@assoc_sources, assoc)
  rescue
    KeyError ->
      raise ArgumentError, "unsupported Exograph association: #{inspect(assoc)}"
  end

  defp predicate_binding({_kind, binding, _value}), do: binding
  defp predicate_binding({_kind, binding, _field, _value}), do: binding
  defp predicate_binding({_kind, binding, _field, _op, _value}), do: binding

  defp structural_predicate?({kind, _binding, _value}) when kind in [:matches, :contains],
    do: true

  defp structural_predicate?(_predicate), do: false

  defp validate!(%Plan{} = plan) do
    validate_source!(plan)
    validate_join_count!(plan)
    validate_join_parents!(plan)
    validate_join_assocs!(plan)
    validate_bindings!(plan)
    validate_predicates!(plan)
    validate_structural_predicates!(plan)
    validate_select!(plan)
    plan
  end

  defp validate_source!(%Plan{source: source}) do
    unless Map.has_key?(@source_assocs, source) do
      raise ArgumentError, "unsupported Exograph source: #{inspect(source)}"
    end
  end

  defp validate_join_count!(%Plan{source: :fragment, joins: joins}) when length(joins) <= 3,
    do: :ok

  defp validate_join_count!(%Plan{source: :fragment}),
    do: raise(ArgumentError, "fragment queries support at most 3 joins")

  defp validate_join_count!(%Plan{source: :definition, joins: joins}) when length(joins) <= 1,
    do: :ok

  defp validate_join_count!(%Plan{source: :definition}),
    do: raise(ArgumentError, "definition queries support only one join")

  defp validate_join_count!(%Plan{joins: []}), do: :ok

  defp validate_join_count!(%Plan{source: source}) do
    raise ArgumentError, "#{source} queries do not support joins"
  end

  defp validate_join_parents!(%Plan{binding: binding, joins: joins}) do
    Enum.each(joins, fn join ->
      unless join.parent == binding do
        raise ArgumentError,
              "unsupported Exograph join parent `#{join.parent}`; joins must target source binding `#{binding}`"
      end
    end)
  end

  defp validate_join_assocs!(%Plan{source: source, joins: joins}) do
    allowed = Map.fetch!(@source_assocs, source)

    Enum.each(joins, fn join ->
      unless join.assoc in allowed do
        raise ArgumentError,
              "association #{inspect(join.assoc)} is not supported for #{source} queries"
      end
    end)

    duplicate_assocs = joins |> Enum.map(& &1.assoc) |> duplicates()

    unless duplicate_assocs == [] do
      raise ArgumentError, "duplicate Exograph join associations: #{inspect(duplicate_assocs)}"
    end
  end

  defp validate_bindings!(%Plan{binding: binding, joins: joins}) do
    bindings = [binding | Enum.map(joins, & &1.binding)]
    duplicate_bindings = duplicates(bindings)

    unless duplicate_bindings == [] do
      raise ArgumentError, "duplicate Exograph bindings: #{inspect(duplicate_bindings)}"
    end
  end

  defp validate_predicates!(%Plan{predicates_by_binding: predicates_by_binding} = plan) do
    allowed = binding_set(plan)

    Enum.each(predicates_by_binding, fn {binding, _predicates} ->
      unless MapSet.member?(allowed, binding) do
        raise ArgumentError, "unknown Exograph binding `#{binding}` in predicate"
      end
    end)
  end

  defp validate_structural_predicates!(%Plan{
         source: :fragment,
         binding: binding,
         structural_predicates: predicates
       }) do
    Enum.each(predicates, fn
      {_kind, ^binding, _pattern} ->
        :ok

      {_kind, other_binding, _pattern} ->
        raise ArgumentError,
              "structural predicates must target fragment binding `#{binding}`, got `#{other_binding}`"
    end)
  end

  defp validate_structural_predicates!(%Plan{structural_predicates: []}), do: :ok

  defp validate_structural_predicates!(%Plan{source: source}) do
    raise ArgumentError,
          "structural predicates are only supported for fragment queries, got #{source}"
  end

  defp validate_select!(%Plan{select: nil}), do: :ok

  defp validate_select!(%Plan{select: {:tuple, bindings}} = plan) do
    Enum.each(bindings, &validate_select_binding!(plan, &1))
  end

  defp validate_select!(%Plan{select: binding} = plan) when is_binary(binding) do
    validate_select_binding!(plan, binding)
  end

  defp validate_select!(%Plan{select: select}) do
    raise ArgumentError, "unsupported Exograph select: #{inspect(select)}"
  end

  defp validate_select_binding!(plan, binding) do
    unless MapSet.member?(binding_set(plan), binding) do
      raise ArgumentError, "unknown Exograph binding `#{binding}` in select"
    end
  end

  defp binding_set(%Plan{binding: binding, joins: joins}) do
    MapSet.new([binding | Enum.map(joins, & &1.binding)])
  end

  defp internal_select(bindings) when is_list(bindings), do: {:tuple, bindings}
  defp internal_select(select), do: select

  defp duplicates(values) do
    values
    |> Enum.frequencies()
    |> Enum.filter(fn {_value, count} -> count > 1 end)
    |> Enum.map(fn {value, _count} -> value end)
  end
end
