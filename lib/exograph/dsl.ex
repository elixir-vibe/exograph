defmodule Exograph.DSL do
  @moduledoc """
  Ecto-shaped query DSL for Exograph.

  The DSL currently supports structural `Fragment` queries and relational
  `Definition` / `Reference` / `CallEdge` queries:

      import Exograph.DSL

      from f in Fragment,
        where: matches(f, "def _ do ... end"),
        where: contains(f, "Repo.transaction(_)")
  """

  alias Exograph.Query
  alias Exograph.Query.{Join, Predicate}

  defmacro from({:in, _meta, [binding_ast, source_ast]}, clauses) when is_list(clauses) do
    binding = binding_name!(binding_ast)
    source = source!(source_ast, __CALLER__)
    joins = joins!(clauses, binding)

    bindings =
      MapSet.new([binding | Enum.map(joins, & &1.binding)])

    predicates = predicates!(clauses, binding, bindings)
    select = select!(Keyword.get(clauses, :select), bindings)
    limit = Keyword.get(clauses, :limit)

    Macro.escape(%Query{
      source: source,
      binding: binding,
      predicates: predicates,
      joins: joins,
      select: select,
      limit: limit
    })
  end

  defmacro matches(_binding, _pattern) do
    raise ArgumentError, "matches/2 can only be used inside Exograph.DSL.from/2"
  end

  defmacro contains(_binding, _pattern) do
    raise ArgumentError, "contains/2 can only be used inside Exograph.DSL.from/2"
  end

  defmacro prefix_search(_field, _value) do
    raise ArgumentError, "prefix_search/2 can only be used inside Exograph.DSL.from/2"
  end

  defmacro assoc(_binding, _name) do
    raise ArgumentError, "assoc/2 can only be used inside Exograph.DSL.from/2"
  end

  defp binding_name!({name, _meta, context}) when is_atom(name) and is_atom(context),
    do: Atom.to_string(name)

  defp binding_name!(ast) do
    raise ArgumentError, "expected a binding such as `f`, got: #{Macro.to_string(ast)}"
  end

  defp source!(source_ast, caller) do
    case Macro.expand(source_ast, caller) do
      Exograph.Package -> :package
      Package -> :package
      Exograph.PackageVersion -> :package_version
      PackageVersion -> :package_version
      Exograph.File -> :file
      File -> :file
      Exograph.Fragment -> :fragment
      Fragment -> :fragment
      Exograph.Definition -> :definition
      Definition -> :definition
      Exograph.Reference -> :reference
      Reference -> :reference
      Exograph.CallEdge -> :call_edge
      CallEdge -> :call_edge
      other -> raise ArgumentError, "unsupported Exograph source: #{inspect(other)}"
    end
  end

  defp joins!(clauses, binding) do
    clauses
    |> Keyword.get_values(:join)
    |> Enum.map(&join!(&1, binding))
  end

  defp join!(
         {:in, _meta, [join_binding_ast, {:assoc, _assoc_meta, [parent_ast, assoc]}]},
         binding
       )
       when is_atom(assoc) do
    join_binding = binding_name!(join_binding_ast)
    assert_binding!(parent_ast, binding)
    %Join{parent: binding, binding: join_binding, association: assoc}
  end

  defp join!(ast, _binding) do
    raise ArgumentError,
          "unsupported Exograph join, expected `j in assoc(binding, :name)`, got: #{Macro.to_string(ast)}"
  end

  defp select!(nil, _bindings), do: nil

  defp select!({left, right}, bindings),
    do: [select_binding!(left, bindings), select_binding!(right, bindings)]

  defp select!({:{}, _meta, items}, bindings),
    do: Enum.map(items, &select_binding!(&1, bindings))

  defp select!(ast, bindings), do: select_binding!(ast, bindings)

  defp select_binding!(ast, bindings) do
    binding = binding_name!(ast)

    unless MapSet.member?(bindings, binding) do
      raise ArgumentError, "unknown Exograph binding `#{binding}` in select"
    end

    binding
  end

  defp predicates!(clauses, binding, bindings) do
    clauses
    |> Keyword.get_values(:where)
    |> Enum.map(&predicate!(&1, binding, bindings))
  end

  defp predicate!({:matches, _meta, [binding_ast, pattern]}, binding, _bindings)
       when is_binary(pattern) do
    assert_binding!(binding_ast, binding)
    %Predicate{op: :matches, binding: binding, value: pattern}
  end

  defp predicate!({:contains, _meta, [binding_ast, pattern]}, binding, _bindings)
       when is_binary(pattern) do
    assert_binding!(binding_ast, binding)
    %Predicate{op: :contains, binding: binding, value: pattern}
  end

  defp predicate!({:prefix_search, _meta, [field_ast, value]}, _binding, bindings)
       when is_binary(value) do
    {:field, field_binding, field} = field!(field_ast, bindings)
    %Predicate{op: :prefix_search, binding: field_binding, field: field, value: value}
  end

  defp predicate!({:==, _meta, [field_ast, value]}, _binding, bindings) do
    {:field, field_binding, field} = field!(field_ast, bindings)
    %Predicate{op: :eq, binding: field_binding, field: field, value: value}
  end

  defp predicate!({op, _meta, [field_ast, value]}, _binding, bindings)
       when op in [:>, :<, :>=, :<=] do
    {:field, field_binding, field} = field!(field_ast, bindings)

    %Predicate{
      op: :cmp,
      binding: field_binding,
      field: field,
      comparison: op,
      value: value
    }
  end

  defp predicate!({:in, _meta, [field_ast, values]}, _binding, bindings) when is_list(values) do
    {:field, field_binding, field} = field!(field_ast, bindings)
    %Predicate{op: :in, binding: field_binding, field: field, value: values}
  end

  defp predicate!(ast, _binding, _bindings) do
    raise ArgumentError, "unsupported Exograph predicate: #{Macro.to_string(ast)}"
  end

  defp assert_binding!({name, _meta, context}, binding) when is_atom(context) do
    if Atom.to_string(name) == binding,
      do: :ok,
      else: raise(ArgumentError, "predicate must target binding `#{binding}`")
  end

  defp assert_binding!(ast, binding) do
    raise ArgumentError,
          "predicate must target binding `#{binding}`, got: #{Macro.to_string(ast)}"
  end

  defp field!({{:., _meta, [binding_ast, field]}, _call_meta, []}, bindings)
       when is_atom(field) do
    binding = binding_name!(binding_ast)

    unless MapSet.member?(bindings, binding) do
      raise ArgumentError, "unknown Exograph binding `#{binding}` in field access"
    end

    {:field, binding, field}
  end

  defp field!(ast, _bindings) do
    raise ArgumentError, "expected a field access such as `d.name`, got: #{Macro.to_string(ast)}"
  end
end
