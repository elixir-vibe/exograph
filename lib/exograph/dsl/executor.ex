defmodule Exograph.DSL.Executor do
  @moduledoc false

  import Ecto.Query
  import Exograph.DSL.Executor.Predicates
  import Exograph.DSL.Executor.Scope

  alias Exograph.{CallEdgeHit, DefinitionHit, Fragment, Hit, ReferenceHit}
  alias Exograph.DSL.{Compiler, JoinSemantics, Plan, Planner, Query, Sources}
  alias Exograph.DSL.Plan.Join
  alias Exograph.Storage.Ecto.FragmentStore, as: EctoFragmentStore
  alias Exograph.Storage.Ecto.InvertedIndex, as: EctoInvertedIndex
  alias Exograph.StructuralQuery

  alias Exograph.Storage.Ecto.{
    CallEdgeRecord,
    DefinitionRecord,
    FragmentRecord,
    Options,
    ReferenceRecord
  }

  def all(index, %Query{} = query, opts) do
    execute(index, Planner.plan(query), opts)
  end

  defp execute(index, %Plan{source: :fragment, joins: []} = plan, opts) do
    fragment_all(index, plan, opts)
  end

  defp execute(index, %Plan{source: :fragment, joins: [%Join{} | _joins]} = plan, opts) do
    fragment_join_all(index, plan, opts)
  end

  defp execute(
         index,
         %Plan{
           source: :definition,
           binding: binding,
           joins: [%Join{parent: binding, binding: join_binding, assoc: :calls}]
         } = plan,
         opts
       ) do
    definition_calls_join_all(index, plan, join_binding, opts)
  end

  defp execute(index, %Plan{source: :definition} = plan, opts) do
    symbol_fact_all(index, plan, opts, :definition)
  end

  defp execute(index, %Plan{source: :reference} = plan, opts) do
    symbol_fact_all(index, plan, opts, :reference)
  end

  defp execute(index, %Plan{source: :call_edge} = plan, opts) do
    call_edge_all(index, plan, opts)
  end

  defp fragment_all(index, plan, opts) do
    limit = Keyword.get(opts, :limit, 50)
    skip = Keyword.get(opts, :skip, 0)
    compiled_query = plan.query |> Compiler.compile() |> StructuralQuery.selector()

    hits =
      index
      |> stream_filtered_fragments(plan, opts)
      |> Stream.flat_map(&verify_fragment(&1, compiled_query))
      |> Stream.drop(skip)
      |> Enum.take(limit)
      |> hydrate_hit_sources(index)

    {:ok, hits}
  end

  defp fragment_join_all(index, plan, opts) do
    limit = Keyword.get(query_opts = opts, :limit, 50)
    skip = Keyword.get(opts, :skip, 0)
    compiled_query = plan.query |> Compiler.compile() |> StructuralQuery.selector()

    hits =
      if structural_plan?(plan) do
        index
        |> stream_joined_fragments(plan, query_opts)
        |> Stream.flat_map(fn {fragment, joined_by_binding} ->
          fragment
          |> verify_fragment(compiled_query)
          |> Enum.map(&select_multi_fragment_join(plan, &1, joined_by_binding))
        end)
      else
        index
        |> stream_joined_fragments(plan, query_opts)
        |> maybe_unique_joined_fragments(index, plan)
        |> Stream.map(fn {fragment, joined_by_binding} ->
          select_multi_fragment_join(
            plan,
            Hit.new(fragment: fragment, score: 1.0),
            joined_by_binding
          )
        end)
      end
      |> Stream.drop(skip)
      |> Enum.take(limit)
      |> hydrate_join_result_fragments(index, plan)

    {:ok, hits}
  end

  @stream_batch_size 500
  @light_fragment_fields [
    :id,
    :package_id,
    :package_version_id,
    :file_id,
    :kind,
    :module,
    :name,
    :arity,
    :line,
    :end_line,
    :mass
  ]
  @light_reference_fields [
    :id,
    :package_id,
    :package_version_id,
    :file_id,
    :fragment_id,
    :kind,
    :module,
    :name,
    :arity,
    :qualified_name,
    :line,
    :column
  ]
  @candidate_fragment_fields [:ast | @light_fragment_fields]

  defp stream_filtered_fragments(index, plan, opts) do
    Stream.resource(
      fn -> {nil, false} end,
      fn
        {_cursor, true} ->
          {:halt, :done}

        {cursor, false} ->
          batch = filtered_fragment_batch(index, plan, opts, cursor)
          done = length(batch) < @stream_batch_size
          next_cursor = if batch == [], do: cursor, else: last_cursor(batch)
          {batch, {next_cursor, done}}
      end,
      fn _acc -> :ok end
    )
  end

  defp filtered_fragment_batch(index, plan, opts, cursor) do
    base_filtered_fragment_query(index, cursor, plan_requires_source?(plan))
    |> where_structural_terms(index, plan)
    |> where_pattern_kind(plan)
    |> where_pattern_name_arity(plan)
    |> where_source_predicates(predicates(plan, plan.binding), plan.binding, :fragment)
    |> where_fragment_scope(opts)
    |> hydrate_fragment_batch(index)
  end

  @def_kinds [:def, :defp, :defmacro, :defmacrop]

  defp where_pattern_kind(queryable, %Plan{query: %{predicates: predicates}}) do
    case Enum.find_value(predicates, &pattern_kind/1) do
      kind when kind in @def_kinds ->
        Ecto.Query.where(queryable, [fragment], fragment.kind == ^kind)

      _ ->
        queryable
    end
  end

  defp pattern_kind({:matches, _binding, pattern}) when is_binary(pattern) do
    case ExAST.Pattern.compile(pattern) do
      {kind, _, _} when kind in @def_kinds -> kind
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp pattern_kind(_), do: nil

  defp where_pattern_name_arity(queryable, %Plan{query: %{predicates: predicates}}) do
    case Enum.find_value(predicates, &pattern_name_arity/1) do
      {name, nil} when is_binary(name) ->
        where(queryable, [fragment], fragment.name == ^name)

      {name, arity} when is_binary(name) and is_integer(arity) ->
        where(queryable, [fragment], fragment.name == ^name and fragment.arity == ^arity)

      _ ->
        queryable
    end
  end

  defp pattern_name_arity({:matches, _binding, pattern}) when is_binary(pattern) do
    case ExAST.Pattern.compile(pattern) do
      ast -> def_pattern_name_arity(ast)
    end
  rescue
    _ -> nil
  end

  defp pattern_name_arity(_), do: nil

  defp def_pattern_name_arity({kind, _, [{name, _, args} | _]})
       when kind in @def_kinds and is_atom(name) and is_list(args) do
    if Enum.all?(args, &match?({:_, _, _}, &1)) or args == [] do
      {Atom.to_string(name), length(args)}
    else
      {Atom.to_string(name), nil}
    end
  end

  defp def_pattern_name_arity(_ast), do: nil

  def stream_structural(index, %Exograph.StructuralQuery{} = compiled_query, opts) do
    term_strings = MapSet.to_list(compiled_query.required_terms)
    term_ids = EctoInvertedIndex.resolve_term_ids(index.inverted, term_strings)
    kind_filter = structural_query_kind(compiled_query)
    {name_filter, arity_filter} = structural_query_name_arity(compiled_query)

    has_column_filters? = kind_filter != nil and name_filter != nil

    Stream.resource(
      fn -> {nil, false} end,
      fn
        {_cursor, true} ->
          {:halt, :done}

        {cursor, false} ->
          batch =
            structural_fragment_batch(
              index,
              if(has_column_filters?, do: [], else: term_ids),
              kind_filter,
              name_filter,
              arity_filter,
              opts,
              cursor
            )

          done = length(batch) < @stream_batch_size
          next_cursor = if batch == [], do: cursor, else: last_cursor(batch)
          {batch, {next_cursor, done}}
      end,
      fn _acc -> :ok end
    )
  end

  defp structural_query_kind(%StructuralQuery{source: pattern}) when is_binary(pattern) do
    case ExAST.Pattern.compile(pattern) do
      {kind, _, _} when kind in @def_kinds -> kind
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp structural_query_kind(_), do: nil

  defp structural_query_name_arity(%StructuralQuery{source: pattern}) when is_binary(pattern) do
    case ExAST.Pattern.compile(pattern) do
      ast -> def_pattern_name_arity(ast) || {nil, nil}
    end
  rescue
    _ -> {nil, nil}
  end

  defp structural_query_name_arity(_), do: {nil, nil}

  defp structural_fragment_batch(
         index,
         term_ids,
         kind_filter,
         name_filter,
         arity_filter,
         opts,
         cursor
       ) do
    query = base_fragment_query(index, cursor)

    query = where_fragment_term_ids(query, index, term_ids)

    query =
      if kind_filter,
        do: where(query, [fragment], fragment.kind == ^kind_filter),
        else: query

    query =
      if name_filter,
        do: where(query, [fragment], fragment.name == ^name_filter),
        else: query

    query =
      if arity_filter,
        do: where(query, [fragment], fragment.arity == ^arity_filter),
        else: query

    query
    |> where_fragment_scope(opts)
    |> hydrate_fragment_batch(index)
  end

  defp base_fragment_query(index, cursor) do
    files_source = Options.files_source(index.inverted.prefix)
    fragments_source = Options.fragments_source(index.inverted.prefix)

    query =
      from(fragment in {fragments_source, FragmentRecord},
        left_join: file in ^files_source,
        on: file.id == fragment.file_id,
        order_by: [asc: file.path, asc: fragment.line, asc: fragment.id],
        limit: ^@stream_batch_size,
        select: {fragment, file.source, file.path}
      )

    where_after_cursor(query, cursor)
  end

  defp base_filtered_fragment_query(index, cursor, include_source?) do
    base_fragment_candidate_query(index, cursor, include_source?)
  end

  defp base_fragment_candidate_query(index, cursor, include_source?) do
    files_source = Options.files_source(index.inverted.prefix)
    fragments_source = Options.fragments_source(index.inverted.prefix)

    query =
      from(fragment in {fragments_source, FragmentRecord},
        left_join: file in ^files_source,
        on: file.id == fragment.file_id,
        order_by: [asc: file.path, asc: fragment.line, asc: fragment.id],
        limit: ^@stream_batch_size
      )
      |> select_fragment_candidate(include_source?)

    where_after_cursor(query, cursor)
  end

  defp select_fragment_candidate(query, true) do
    select(query, [fragment, file], {
      map(fragment, @candidate_fragment_fields),
      file.source,
      file.path
    })
  end

  defp select_fragment_candidate(query, false) do
    select(query, [fragment, file], {
      map(fragment, @candidate_fragment_fields),
      nil,
      file.path
    })
  end

  defp where_after_cursor(query, nil), do: query

  defp where_after_cursor(query, {path, line, id}) do
    where(
      query,
      [fragment, file],
      file.path > ^path or
        (file.path == ^path and fragment.line > ^line) or
        (file.path == ^path and fragment.line == ^line and fragment.id > ^id)
    )
  end

  defp last_cursor(batch) do
    last = List.last(batch)
    {last.file || "", last.line, last.id}
  end

  defp hydrate_fragment_batch(query, index) do
    index.inverted.repo.all(query)
    |> Enum.map(fn {fragment, source, path} ->
      hydrate_query_fragment(fragment, source, path)
    end)
  end

  defp hydrate_query_fragment(%FragmentRecord{} = fragment, source, path) do
    Options.hydrate_fragment(fragment, source, path)
  end

  defp hydrate_query_fragment(fragment, source, path) when is_map(fragment) do
    %Fragment{
      id: fragment.id,
      package_id: fragment.package_id,
      package_version_id: fragment.package_version_id,
      file_id: fragment.file_id,
      file: path,
      source: source,
      ast: :erlang.binary_to_term(fragment.ast),
      kind: fragment.kind,
      module: fragment.module,
      name: fragment.name,
      arity: fragment.arity,
      line: fragment.line,
      end_line: fragment.end_line,
      mass: fragment.mass
    }
  end

  defp maybe_unique_joined_fragments(stream, index, plan) do
    if light_join_projection?(index, plan) do
      Stream.uniq_by(stream, fn {fragment, _joined_by_binding} -> fragment.id end)
    else
      stream
    end
  end

  defp stream_joined_fragments(index, %Plan{joins: [_]} = plan, opts) do
    Stream.resource(
      fn -> {nil, false} end,
      fn
        {_cursor, true} ->
          {:halt, :done}

        {cursor, false} ->
          candidate_limit = joined_fragment_batch_limit(index, plan, opts)
          batch_opts = Keyword.put(opts, :candidate_limit, candidate_limit)
          batch = joined_fragments(index, plan, batch_opts, cursor)
          done = length(batch) < candidate_limit

          next_cursor =
            if batch == [],
              do: cursor,
              else: last_cursor(Enum.map(batch, &elem(&1, 0)))

          {batch, {next_cursor, done}}
      end,
      fn _acc -> :ok end
    )
  end

  defp stream_joined_fragments(index, plan, opts) do
    joined_fragments(
      index,
      plan,
      Keyword.put_new_lazy(opts, :candidate_limit, fn ->
        EctoFragmentStore.count(index.fragment_store)
      end),
      nil
    )
  end

  defp joined_fragments(index, %Plan{joins: [join]} = plan, opts, offset) do
    join_predicates = predicates(plan, join.binding)

    if join_predicates != [] do
      joined_fragments_fact_first(index, plan, join, opts, offset)
    else
      joined_fragments_fragment_first(index, plan, join, opts, offset)
    end
  end

  defp joined_fragments(index, %Plan{joins: [_first, _second]} = plan, opts, _offset),
    do: joined_fragments_two(index, plan, opts)

  defp joined_fragments(index, %Plan{joins: [_first, _second, _third]} = plan, opts, _offset),
    do: joined_fragments_three(index, plan, opts)

  defp joined_fragments_fact_first(index, plan, join, opts, cursor) do
    candidate_limit = candidate_limit(index, opts)
    files_source = Options.files_source(index.inverted.prefix)
    fragments_source = Options.fragments_source(index.inverted.prefix)
    function_fragment_kinds = JoinSemantics.function_fragment_kinds()

    {join_table, join_record} = Sources.primary_source(join.assoc, index.inverted.prefix)

    containing_fragment =
      if not light_join_projection?(index, plan) do
        from(f in {fragments_source, FragmentRecord},
          where:
            f.file_id == parent_as(:joined).file_id and
              f.kind in ^function_fragment_kinds and
              f.line <= parent_as(:joined).line and
              (is_nil(f.end_line) or f.end_line >= parent_as(:joined).line),
          order_by: [desc: f.line],
          limit: 1
        )
      else
        from(f in {fragments_source, FragmentRecord},
          where:
            f.file_id == parent_as(:joined).file_id and
              f.kind in ^function_fragment_kinds and
              f.line <= parent_as(:joined).line and
              (is_nil(f.end_line) or f.end_line >= parent_as(:joined).line),
          order_by: [desc: f.line],
          limit: 1,
          select: map(f, @light_fragment_fields)
        )
      end

    query =
      from(joined in {join_table, join_record},
        as: :joined,
        inner_lateral_join: frag in subquery(containing_fragment),
        as: :fragment,
        on: true,
        left_join: file in ^files_source,
        on: file.id == frag.file_id,
        order_by: [asc: file.path, asc: frag.line, asc: frag.id],
        limit: ^candidate_limit
      )
      |> maybe_distinct_joined_fragment(index, plan, :fact_first)
      |> select_joined_fragment(index, plan, :fact_first, join.assoc)

    query =
      case cursor do
        nil ->
          query

        {path, line, id} ->
          where(
            query,
            [_joined, frag, file],
            file.path > ^path or
              (file.path == ^path and frag.line > ^line) or
              (file.path == ^path and frag.line == ^line and frag.id > ^id)
          )
      end

    query
    |> where_first_binding_join_predicates(predicates(plan, join.binding), join.assoc)
    |> where_structural_terms_second(index, plan)
    |> where_second_binding_predicates(predicates(plan, plan.binding), plan.binding, :fragment)
    |> where_fragment_scope_second(opts)
    |> index.inverted.repo.all()
    |> Enum.map(fn {fragment, source, path, joined} ->
      {
        hydrate_joined_fragment(fragment, source, path, index, plan),
        %{join.binding => joined_value(join.assoc, joined)}
      }
    end)
  end

  defp joined_fragments_fragment_first(index, plan, join, opts, cursor) do
    candidate_limit = candidate_limit(index, opts)
    files_source = Options.files_source(index.inverted.prefix)
    fragments_source = Options.fragments_source(index.inverted.prefix)
    function_fragment_kinds = JoinSemantics.function_fragment_kinds()

    query =
      from(fragment in {fragments_source, FragmentRecord},
        as: :fragment,
        join: joined in ^Sources.join_source(join.assoc, index.inverted.prefix),
        on: joined.file_id == fragment.file_id,
        where:
          fragment.kind in ^function_fragment_kinds and joined.line >= fragment.line and
            (is_nil(fragment.end_line) or joined.line <= fragment.end_line),
        left_join: file in ^files_source,
        on: file.id == fragment.file_id,
        order_by: [asc: file.path, asc: fragment.line, asc: fragment.id],
        limit: ^candidate_limit
      )
      |> maybe_distinct_joined_fragment(index, plan, :fragment_first)
      |> select_joined_fragment(index, plan, :fragment_first, join.assoc)

    query =
      case cursor do
        nil ->
          query

        {path, line, id} ->
          where(
            query,
            [fragment, _joined, file],
            file.path > ^path or
              (file.path == ^path and fragment.line > ^line) or
              (file.path == ^path and fragment.line == ^line and fragment.id > ^id)
          )
      end

    query
    |> where_structural_terms(index, plan)
    |> where_source_predicates(predicates(plan, plan.binding), nil, :fragment)
    |> where_second_binding_predicates(predicates(plan, join.binding), join.binding, join.assoc)
    |> where_fragment_scope(opts)
    |> index.inverted.repo.all()
    |> Enum.map(fn {fragment, source, path, joined} ->
      {
        hydrate_joined_fragment(fragment, source, path, index, plan),
        %{join.binding => joined_value(join.assoc, joined)}
      }
    end)
  end

  defp joined_fragments_two(index, %Plan{joins: [first_join, second_join]} = plan, opts) do
    candidate_limit = candidate_limit(index, opts)
    files_source = Options.files_source(index.inverted.prefix)
    fragments_source = Options.fragments_source(index.inverted.prefix)
    function_fragment_kinds = JoinSemantics.function_fragment_kinds()

    from(fragment in {fragments_source, FragmentRecord},
      as: :fragment,
      join: first in ^Sources.join_source(first_join.assoc, index.inverted.prefix),
      on:
        first.file_id == fragment.file_id and first.line >= fragment.line and
          (is_nil(fragment.end_line) or first.line <= fragment.end_line),
      join: second in ^Sources.join_source(second_join.assoc, index.inverted.prefix),
      on:
        second.file_id == fragment.file_id and second.line >= fragment.line and
          (is_nil(fragment.end_line) or second.line <= fragment.end_line),
      left_join: file in ^files_source,
      on: file.id == fragment.file_id,
      where: fragment.kind in ^function_fragment_kinds,
      distinct: fragment.id,
      order_by: [asc: file.path, asc: fragment.line, asc: fragment.id],
      limit: ^candidate_limit,
      select: {fragment, file.source, file.path, first, second}
    )
    |> JoinSemantics.where_call_definition_pairs(plan)
    |> where_structural_terms(index, plan)
    |> where_source_predicates(predicates(plan, plan.binding), nil, :fragment)
    |> where_second_binding_predicates(
      predicates(plan, first_join.binding),
      first_join.binding,
      first_join.assoc
    )
    |> where_third_binding_predicates(
      predicates(plan, second_join.binding),
      second_join.binding,
      second_join.assoc
    )
    |> where_fragment_scope(opts)
    |> index.inverted.repo.all()
    |> Enum.map(fn {fragment, source, path, first, second} ->
      {
        Options.hydrate_fragment(fragment, source, path),
        %{
          first_join.binding => joined_value(first_join.assoc, first),
          second_join.binding => joined_value(second_join.assoc, second)
        }
      }
    end)
  end

  defp joined_fragments_three(
         index,
         %Plan{joins: [first_join, second_join, third_join]} = plan,
         opts
       ) do
    candidate_limit = candidate_limit(index, opts)
    files_source = Options.files_source(index.inverted.prefix)
    fragments_source = Options.fragments_source(index.inverted.prefix)
    function_fragment_kinds = JoinSemantics.function_fragment_kinds()

    from(fragment in {fragments_source, FragmentRecord},
      as: :fragment,
      join: first in ^Sources.join_source(first_join.assoc, index.inverted.prefix),
      on:
        first.file_id == fragment.file_id and first.line >= fragment.line and
          (is_nil(fragment.end_line) or first.line <= fragment.end_line),
      join: second in ^Sources.join_source(second_join.assoc, index.inverted.prefix),
      on:
        second.file_id == fragment.file_id and second.line >= fragment.line and
          (is_nil(fragment.end_line) or second.line <= fragment.end_line),
      join: third in ^Sources.join_source(third_join.assoc, index.inverted.prefix),
      on: third.file_id == fragment.file_id,
      left_join: file in ^files_source,
      on: file.id == fragment.file_id,
      where: fragment.kind in ^function_fragment_kinds,
      distinct: fragment.id,
      order_by: [asc: file.path, asc: fragment.line, asc: fragment.id],
      limit: ^candidate_limit,
      select: {fragment, file.source, file.path, first, second, third}
    )
    |> JoinSemantics.where_call_definition_pairs(plan)
    |> where_structural_terms(index, plan)
    |> where_source_predicates(predicates(plan, plan.binding), nil, :fragment)
    |> where_second_binding_predicates(
      predicates(plan, first_join.binding),
      first_join.binding,
      first_join.assoc
    )
    |> where_third_binding_predicates(
      predicates(plan, second_join.binding),
      second_join.binding,
      second_join.assoc
    )
    |> where_fourth_binding_predicates(
      predicates(plan, third_join.binding),
      third_join.binding,
      third_join.assoc
    )
    |> where_fragment_scope(opts)
    |> index.inverted.repo.all()
    |> Enum.map(fn {fragment, source, path, first, second, third} ->
      {
        Options.hydrate_fragment(fragment, source, path),
        %{
          first_join.binding => joined_value(first_join.assoc, first),
          second_join.binding => joined_value(second_join.assoc, second),
          third_join.binding => joined_value(third_join.assoc, third)
        }
      }
    end)
  end

  defp definition_calls_join_all(index, plan, call_edge_binding, opts) do
    limit = Keyword.get(opts, :limit, 50)
    files_source = Options.files_source(index.inverted.prefix)
    fragments_source = Options.fragments_source(index.inverted.prefix)

    queryable =
      from(definition in Options.definitions_source(index.inverted.prefix),
        join: edge in ^Options.call_edges_source(index.inverted.prefix),
        on: edge.caller_qualified_name == definition.qualified_name,
        left_join: fragment in ^{fragments_source, FragmentRecord},
        on: fragment.id == definition.fragment_id,
        left_join: file in ^files_source,
        on: file.id == fragment.file_id,
        order_by: [asc: definition.qualified_name, asc: edge.callee_qualified_name, asc: edge.id],
        limit: ^limit,
        select: {definition, fragment, nil, file.path}
      )
      |> where_source_predicates(predicates(plan, plan.binding), nil, :definition)
      |> where_second_binding_call_edge_predicates(
        predicates(plan, call_edge_binding),
        call_edge_binding
      )
      |> where_scope(opts)

    results =
      index.inverted.repo.all(queryable)
      |> Enum.map(&hit(&1, Options.definitions_source(index.inverted.prefix)))

    {:ok, results}
  end

  defp maybe_distinct_joined_fragment(query, index, plan, binding) do
    if light_join_projection?(index, plan) do
      query
    else
      distinct_binding(query, binding)
    end
  end

  defp distinct_binding(query, :fact_first), do: distinct(query, [_joined, frag], frag.id)
  defp distinct_binding(query, :fragment_first), do: distinct(query, [fragment], fragment.id)

  defp select_joined_fragment(query, index, plan, :fact_first, assoc) do
    if light_join_projection?(index, plan) do
      select_light_joined_fragment(query, :fact_first, assoc)
    else
      select(query, [joined, frag, file], {frag, file.source, file.path, joined})
    end
  end

  defp select_joined_fragment(query, index, plan, :fragment_first, assoc) do
    if light_join_projection?(index, plan) do
      select_light_joined_fragment(query, :fragment_first, assoc)
    else
      select(query, [fragment, joined, file], {fragment, file.source, file.path, joined})
    end
  end

  defp select_light_joined_fragment(query, :fact_first, :references) do
    select(query, [joined, frag, file], {
      map(frag, @light_fragment_fields),
      file.source,
      file.path,
      map(joined, @light_reference_fields)
    })
  end

  defp select_light_joined_fragment(query, :fragment_first, :references) do
    select(query, [fragment, joined, file], {
      map(fragment, @light_fragment_fields),
      file.source,
      file.path,
      map(joined, @light_reference_fields)
    })
  end

  defp select_light_joined_fragment(query, :fact_first, _assoc) do
    select(
      query,
      [joined, frag, file],
      {map(frag, @light_fragment_fields), file.source, file.path, joined}
    )
  end

  defp select_light_joined_fragment(query, :fragment_first, _assoc) do
    select(query, [fragment, joined, file], {
      map(fragment, @light_fragment_fields),
      file.source,
      file.path,
      joined
    })
  end

  defp select_multi_fragment_join(%Plan{select: nil}, hit, _joined_by_binding), do: hit

  defp select_multi_fragment_join(
         %Plan{binding: binding, select: binding},
         hit,
         _joined_by_binding
       ),
       do: hit

  defp select_multi_fragment_join(
         %Plan{binding: binding, select: select},
         _hit,
         joined_by_binding
       )
       when is_atom(select) and select != binding do
    Map.fetch!(joined_by_binding, select)
  end

  defp select_multi_fragment_join(
         %Plan{binding: binding, select: {:tuple, bindings}},
         hit,
         joined_by_binding
       ) do
    bindings
    |> Enum.map(fn selected_binding ->
      if selected_binding == binding,
        do: hit,
        else: Map.fetch!(joined_by_binding, selected_binding)
    end)
    |> List.to_tuple()
  end

  defp joined_value(:definitions, %DefinitionRecord{} = joined),
    do: DefinitionRecord.to_definition(joined)

  defp joined_value(:references, %ReferenceRecord{} = joined),
    do: ReferenceRecord.to_reference(joined)

  defp joined_value(:calls, %CallEdgeRecord{} = joined), do: CallEdgeRecord.to_call_edge(joined)

  defp joined_value(:definitions, joined) when is_map(joined),
    do: struct(Exograph.Definition, joined)

  defp joined_value(:references, joined) when is_map(joined),
    do: struct(Exograph.Reference, joined)

  defp joined_value(:calls, joined) when is_map(joined), do: struct(Exograph.CallEdge, joined)

  defp hydrate_joined_fragment(fragment, source, path, index, plan) do
    if light_join_projection?(index, plan) do
      hydrate_light_fragment(fragment, source, path)
    else
      Options.hydrate_fragment(fragment, source, path)
    end
  end

  defp hydrate_light_fragment(record, source, path) when is_map(record) do
    %Fragment{
      id: record.id,
      package_id: record.package_id,
      package_version_id: record.package_version_id,
      file_id: record.file_id,
      file: path,
      source: source,
      kind: record.kind,
      module: record.module,
      name: record.name,
      arity: record.arity,
      line: record.line,
      end_line: record.end_line,
      mass: record.mass
    }
  end

  defp hydrate_join_result_fragments(results, index, plan) do
    if light_join_projection?(index, plan) do
      fragments = full_fragments(index, result_fragment_ids_list(results))
      Enum.map(results, &replace_result_fragment(&1, fragments))
    else
      results
    end
  end

  defp result_fragment_ids_list(results) do
    results
    |> Enum.flat_map(&result_fragment_ids/1)
    |> Enum.uniq()
  end

  defp result_fragment_ids(%Hit{fragment: %Fragment{id: id}}) when is_integer(id), do: [id]
  defp result_fragment_ids(%Fragment{id: id}) when is_integer(id), do: [id]

  defp result_fragment_ids(tuple) when is_tuple(tuple) do
    tuple
    |> Tuple.to_list()
    |> Enum.flat_map(&result_fragment_ids/1)
  end

  defp result_fragment_ids(_result), do: []

  defp replace_result_fragment(%Hit{fragment: %Fragment{id: id}} = hit, fragments) do
    case Map.fetch(fragments, id) do
      {:ok, fragment} -> %{hit | fragment: fragment}
      :error -> hit
    end
  end

  defp replace_result_fragment(%Fragment{id: id} = fragment, fragments) do
    Map.get(fragments, id, fragment)
  end

  defp replace_result_fragment(tuple, fragments) when is_tuple(tuple) do
    tuple
    |> Tuple.to_list()
    |> Enum.map(&replace_result_fragment(&1, fragments))
    |> List.to_tuple()
  end

  defp replace_result_fragment(result, _fragments), do: result

  defp full_fragments(_index, []), do: %{}

  defp full_fragments(index, ids) do
    files_source = Options.files_source(index.inverted.prefix)
    fragments_source = Options.fragments_source(index.inverted.prefix)

    from(fragment in {fragments_source, FragmentRecord},
      join: file in ^files_source,
      on: file.id == fragment.file_id,
      where: fragment.id in ^ids,
      select: {fragment, file.source, file.path}
    )
    |> index.inverted.repo.all()
    |> Map.new(fn {fragment, source, path} ->
      hydrated = Options.hydrate_fragment(fragment, source, path)
      {hydrated.id, hydrated}
    end)
  end

  defp structural_plan?(%Plan{structural_predicates: predicates}), do: predicates != []

  defp light_join_projection?(_index, %Plan{binding: binding, select: select} = plan)
       when select in [nil, binding] do
    not structural_plan?(plan)
  end

  defp light_join_projection?(_index, _plan), do: false

  defp plan_requires_source?(%Plan{query: query}) do
    query
    |> Compiler.compile()
    |> StructuralQuery.selector()
    |> StructuralQuery.requires_source?()
  end

  defp hydrate_hit_sources(hits, index) do
    missing_source_ids =
      hits
      |> Enum.flat_map(fn
        %Hit{fragment: %Fragment{id: id, source: nil}} when is_integer(id) -> [id]
        _ -> []
      end)
      |> Enum.uniq()

    if missing_source_ids == [] do
      hits
    else
      sources = fragment_sources(index, missing_source_ids)

      Enum.map(hits, fn
        %Hit{fragment: %Fragment{id: id} = fragment} = hit ->
          case Map.fetch(sources, id) do
            {:ok, {source, path}} -> %{hit | fragment: %{fragment | source: source, file: path}}
            :error -> hit
          end

        hit ->
          hit
      end)
    end
  end

  defp fragment_sources(index, ids) do
    files_source = Options.files_source(index.inverted.prefix)
    fragments_source = Options.fragments_source(index.inverted.prefix)

    from(fragment in {fragments_source, FragmentRecord},
      join: file in ^files_source,
      on: file.id == fragment.file_id,
      where: fragment.id in ^ids,
      select: {fragment.id, file.source, file.path}
    )
    |> index.inverted.repo.all()
    |> Map.new(fn {id, source, path} -> {id, {source, path}} end)
  end

  defp verify_fragment(fragment, compiled_query) do
    case StructuralQuery.verify(compiled_query, fragment) do
      {:ok, matches} ->
        Enum.map(matches, &Hit.with_match(Hit.new(fragment: fragment, score: 1.0), &1))

      :error ->
        []
    end
  end

  defp joined_fragment_batch_limit(index, plan, opts) do
    if structural_plan?(plan) do
      @stream_batch_size
    else
      requested = Keyword.get(opts, :limit, 50) + Keyword.get(opts, :skip, 0)

      _index = index
      min(max(requested * 3, requested), @stream_batch_size)
    end
  end

  defp candidate_limit(index, opts) do
    Keyword.get_lazy(opts, :candidate_limit, fn ->
      EctoFragmentStore.count(index.fragment_store)
    end)
  end

  defp predicates(%Plan{predicates_by_binding: predicates_by_binding}, binding) do
    Map.get(predicates_by_binding, binding, [])
  end

  defp symbol_fact_all(index, plan, opts, source_name) do
    source = Sources.source(source_name, index.inverted.prefix)
    limit = Keyword.get(opts, :limit, 50)
    skip = Keyword.get(opts, :skip, 0)
    files_source = Options.files_source(index.inverted.prefix)
    fragments_source = Options.fragments_source(index.inverted.prefix)

    query =
      from(fact in source,
        left_join: fragment in ^{fragments_source, FragmentRecord},
        on: fragment.id == fact.fragment_id,
        left_join: file in ^files_source,
        on: file.id == fragment.file_id,
        order_by: [asc: fact.qualified_name, asc: fact.line, asc: fact.id],
        offset: ^skip,
        limit: ^limit,
        select: {fact, fragment, nil, file.path}
      )
      |> where_source_predicates(predicates(plan, plan.binding), nil, source_name)
      |> where_scope(opts)

    results =
      index.inverted.repo.all(query)
      |> Enum.map(&hit(&1, source))

    {:ok, results}
  end

  defp call_edge_all(index, plan, opts) do
    limit = Keyword.get(opts, :limit, 50)
    skip = Keyword.get(opts, :skip, 0)

    query =
      from(edge in Options.call_edges_source(index.inverted.prefix),
        order_by: [asc: edge.caller_qualified_name, asc: edge.callee_qualified_name, asc: edge.id],
        offset: ^skip,
        limit: ^limit,
        select: edge
      )
      |> where_call_edge_predicates(predicates(plan, plan.binding))
      |> where_scope(opts)

    results =
      index.inverted.repo.all(query)
      |> Enum.map(fn edge ->
        CallEdgeHit.new(call_edge: CallEdgeRecord.to_call_edge(edge), score: 1.0)
      end)

    {:ok, results}
  end

  defp hit({fact, fragment, source, path}, {_table, DefinitionRecord}) do
    DefinitionHit.new(
      definition: DefinitionRecord.to_definition(fact),
      fragment: hydrate_fragment(fragment, source, path),
      score: 1.0
    )
  end

  defp hit({fact, fragment, source, path}, {_table, ReferenceRecord}) do
    ReferenceHit.new(
      reference: ReferenceRecord.to_reference(fact),
      fragment: hydrate_fragment(fragment, source, path),
      score: 1.0
    )
  end

  defp hydrate_fragment(nil, _source, _path), do: nil

  defp hydrate_fragment(fragment, source, path),
    do: Options.hydrate_fragment(fragment, source, path)
end
