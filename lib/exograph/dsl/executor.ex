defmodule Exograph.DSL.Executor do
  @moduledoc false

  import Ecto.Query
  import Exograph.DSL.Executor.Predicates
  import Exograph.DSL.Executor.Scope

  alias Exograph.{CallEdgeHit, DefinitionHit, Fragment, Hit, Ident, ReferenceHit}
  alias Exograph.DSL.{Compiler, Plan, Planner, Sources}
  alias Exograph.Query
  alias Exograph.DSL.Executor.JoinBuilder
  alias Exograph.DSL.Plan.Join
  alias Exograph.Storage.{FragmentStore, Hydration, InvertedIndex}
  alias Exograph.StructuralQuery

  alias Exograph.Storage.{
    CallEdgeRecord,
    DefinitionRecord,
    FragmentRecord,
    Schema,
    ReferenceRecord
  }

  def all(index, %Query{} = query, opts) do
    execute(index, Planner.plan(query), opts)
  end

  def count(index, %Query{} = query, opts \\ []) do
    do_count(index, Planner.plan(query), opts)
  end

  defp do_count(index, %Plan{source: :fragment, joins: []} = plan, opts) do
    if exact_fragment_count_supported?(plan) do
      verifier = fragment_verifier(plan.query)

      count =
        index
        |> stream_filtered_fragments(plan, Keyword.drop(opts, [:limit, :skip]))
        |> Stream.flat_map(&verify_fragment(&1, verifier))
        |> Enum.count()

      {:ok, count}
    else
      :unknown
    end
  end

  defp do_count(index, %Plan{source: source, joins: []} = plan, opts)
       when source in [:package, :package_version, :file] do
    query =
      source
      |> Sources.source(index.inverted.prefix)
      |> where_source_predicates(predicates(plan, plan.binding), nil, source)
      |> where_scope(Keyword.drop(opts, [:limit, :skip]))

    {:ok, index.inverted.repo.aggregate(query, :count)}
  end

  defp do_count(_index, _plan, _opts), do: :unknown

  defp execute(index, %Plan{source: source, joins: []} = plan, opts)
       when source in [:package, :package_version, :file] do
    entity_all(index, plan, opts)
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
    verifier = fragment_verifier(plan.query)

    hits =
      index
      |> stream_filtered_fragments(plan, opts)
      |> Stream.flat_map(&verify_fragment(&1, verifier))
      |> Stream.drop(skip)
      |> Enum.take(limit)
      |> hydrate_hit_sources(index)

    {:ok, hits}
  end

  defp fragment_join_all(index, plan, opts) do
    limit = Keyword.get(query_opts = opts, :limit, 50)
    skip = Keyword.get(opts, :skip, 0)
    verifier = fragment_verifier(plan.query)

    hits =
      if structural_plan?(plan) do
        index
        |> stream_joined_fragments(plan, query_opts)
        |> Stream.flat_map(fn {fragment, joined_by_binding} ->
          fragment
          |> verify_fragment(verifier)
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
    :node_pre,
    :node_post,
    :kind,
    :module,
    :name,
    :arity,
    :line,
    :end_line,
    :mass
  ]
  @candidate_fragment_fields @light_fragment_fields

  defp stream_filtered_fragments(index, plan, opts) do
    Stream.resource(
      fn -> {Keyword.get(opts, :cursor), false} end,
      fn
        {_cursor, true} ->
          {:halt, :done}

        {cursor, false} ->
          batch = filtered_fragment_batch(index, plan, opts, cursor)
          done = length(batch) < fragment_candidate_limit(plan, opts)
          next_cursor = if batch == [], do: cursor, else: last_cursor(batch)
          {batch, {next_cursor, done}}
      end,
      fn _acc -> :ok end
    )
  end

  defp filtered_fragment_batch(index, plan, opts, cursor) do
    base_filtered_fragment_query(index, cursor, fragment_candidate_limit(plan, opts))
    |> where_fragment_text_contains(plan)
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
    case Exograph.PatternParser.parse!(pattern) do
      {kind, _, _} when kind in @def_kinds -> kind
      _ -> nil
    end
  rescue
    ArgumentError -> nil
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
    case Exograph.PatternParser.parse!(pattern) do
      ast -> def_pattern_name_arity(ast)
    end
  rescue
    ArgumentError -> nil
  end

  defp pattern_name_arity(_), do: nil

  defp def_pattern_name_arity({kind, _, [{name, _, args} | _]})
       when kind in @def_kinds and is_list(args) do
    name = Ident.name(name)

    if Enum.all?(args, &match?({:_, _, _}, &1)) or args == [] do
      {name, length(args)}
    else
      {name, nil}
    end
  end

  defp def_pattern_name_arity(_ast), do: nil

  defp exact_fragment_count_supported?(%Plan{
         query: %Query{binding: binding, predicates: predicates}
       }) do
    Enum.any?(predicates, fn
      {:matches, ^binding, pattern} when is_binary(pattern) ->
        match?(
          {_name, arity} when is_integer(arity),
          pattern_name_arity({:matches, binding, pattern})
        )

      _predicate ->
        false
    end)
  end

  @doc false
  def structural_candidate_query(index, %Exograph.StructuralQuery{} = compiled_query, opts \\ []) do
    term_strings = MapSet.to_list(compiled_query.required_terms)
    term_ids = resolve_required_term_ids(index, term_strings)
    kind_filter = structural_query_kind(compiled_query)
    {name_filter, arity_filter} = structural_query_name_arity(compiled_query)
    has_column_filters? = kind_filter != nil and name_filter != nil

    candidate_limit = Keyword.get(opts, :candidate_limit, fragment_candidate_limit(opts))

    query =
      index
      |> base_fragment_query(Keyword.get(opts, :cursor), candidate_limit)
      |> exclude(:select)
      |> select([fragment], fragment.id)

    query = where_required_term_ids(query, index, if(has_column_filters?, do: [], else: term_ids))

    query =
      if kind_filter, do: where(query, [fragment], fragment.kind == ^kind_filter), else: query

    query =
      if name_filter, do: where(query, [fragment], fragment.name == ^name_filter), else: query

    query =
      if arity_filter, do: where(query, [fragment], fragment.arity == ^arity_filter), else: query

    where_fragment_scope(query, opts)
  end

  def stream_structural(index, %Exograph.StructuralQuery{} = compiled_query, opts) do
    term_strings = MapSet.to_list(compiled_query.required_terms)
    term_ids = resolve_required_term_ids(index, term_strings)
    kind_filter = structural_query_kind(compiled_query)
    {name_filter, arity_filter} = structural_query_name_arity(compiled_query)

    has_column_filters? = kind_filter != nil and name_filter != nil

    Stream.resource(
      fn -> {Keyword.get(opts, :cursor), false} end,
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

          done = length(batch) < structural_fragment_candidate_limit(opts)
          next_cursor = if batch == [], do: cursor, else: last_cursor(batch)
          {batch, {next_cursor, done}}
      end,
      fn _acc -> :ok end
    )
  end

  defp resolve_required_term_ids(_index, []), do: []

  defp resolve_required_term_ids(index, terms) do
    ids = InvertedIndex.resolve_term_ids(index.inverted, terms)
    if length(ids) == length(Enum.uniq(terms)), do: ids, else: :missing
  end

  defp where_required_term_ids(query, _index, :missing), do: where(query, false)
  defp where_required_term_ids(query, index, ids), do: where_fragment_term_ids(query, index, ids)

  defp structural_query_kind(%StructuralQuery{source: pattern}) when is_binary(pattern) do
    case Exograph.PatternParser.parse!(pattern) do
      {kind, _, _} when kind in @def_kinds -> kind
      _ -> nil
    end
  rescue
    ArgumentError -> nil
  end

  defp structural_query_kind(_), do: nil

  defp structural_query_name_arity(%StructuralQuery{source: pattern}) when is_binary(pattern) do
    case Exograph.PatternParser.parse!(pattern) do
      ast -> def_pattern_name_arity(ast) || {nil, nil}
    end
  rescue
    ArgumentError -> {nil, nil}
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
    query = base_fragment_query(index, cursor, structural_fragment_candidate_limit(opts))

    query = where_required_term_ids(query, index, term_ids)

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
    |> hydrate_structural_fragment_batch(index)
  end

  defp base_fragment_query(index, cursor, candidate_limit) do
    fragments_source = Schema.fragments_source(index.inverted.prefix)

    query =
      from(fragment in {fragments_source, FragmentRecord},
        order_by: [asc: fragment.file_id, asc: fragment.id],
        limit: ^candidate_limit,
        select: fragment
      )

    where_fragment_after_cursor(query, cursor)
  end

  defp base_filtered_fragment_query(index, cursor, candidate_limit) do
    base_fragment_candidate_query(index, cursor, candidate_limit)
  end

  defp base_fragment_candidate_query(index, cursor, candidate_limit) do
    files_source = Schema.files_source(index.inverted.prefix)
    versions_source = Schema.package_versions_source(index.inverted.prefix)
    packages_source = Schema.packages_source(index.inverted.prefix)
    fragments_source = Schema.fragments_source(index.inverted.prefix)

    query =
      from(fragment in {fragments_source, FragmentRecord},
        left_join: file in ^files_source,
        on: file.id == fragment.file_id,
        left_join: version in ^versions_source,
        on: version.id == fragment.package_version_id,
        left_join: package in ^packages_source,
        on: package.id == version.package_id,
        order_by: [asc: fragment.file_id, asc: fragment.id],
        limit: ^candidate_limit
      )
      |> select_fragment_candidate()

    where_after_cursor(query, cursor)
  end

  defp select_fragment_candidate(query) do
    select(query, [fragment, file, version, package], {
      map(fragment, @candidate_fragment_fields),
      file.path,
      version.version,
      package.name
    })
  end

  defp where_fragment_after_cursor(query, nil), do: query

  defp where_fragment_after_cursor(query, {file_id, id}) do
    where(
      query,
      [fragment],
      fragment.file_id > ^file_id or
        (fragment.file_id == ^file_id and fragment.id > ^id)
    )
  end

  defp where_after_cursor(query, nil), do: query

  defp where_after_cursor(query, {file_id, id}) do
    where(
      query,
      [fragment, _file, _version, _package],
      fragment.file_id > ^file_id or
        (fragment.file_id == ^file_id and fragment.id > ^id)
    )
  end

  defp last_cursor(batch) do
    last = List.last(batch)
    {last.file_id, last.id}
  end

  defp hydrate_fragment_batch(query, index) do
    rows = index.inverted.repo.all(query)
    fragments = Enum.map(rows, &elem(&1, 0))
    files = load_fragment_files(index, fragments)

    locators =
      Map.new(files, fn {file_id, {_source, _path, _package_version, _package_name, file_ast}} ->
        {file_id, Hydration.locator(file_ast)}
      end)

    Enum.map(rows, fn {fragment, path, package_version, package_name} ->
      {source, _path, _package_version, _package_name, file_ast} =
        Map.fetch!(files, fragment.file_id)

      hydrate_query_fragment(
        fragment,
        source,
        path,
        package_version,
        package_name,
        file_ast,
        Map.fetch!(locators, fragment.file_id)
      )
    end)
  end

  defp hydrate_structural_fragment_batch(query, index) do
    fragments = index.inverted.repo.all(query)
    files = load_fragment_files(index, fragments)

    locators =
      Map.new(files, fn {file_id, {_source, _path, _package_version, _package_name, file_ast}} ->
        {file_id, Hydration.locator(file_ast)}
      end)

    Enum.map(fragments, fn fragment ->
      {source, path, package_version, package_name, file_ast} =
        Map.fetch!(files, fragment.file_id)

      hydrate_query_fragment(
        fragment,
        source,
        path,
        package_version,
        package_name,
        file_ast,
        Map.fetch!(locators, fragment.file_id)
      )
    end)
  end

  defp load_fragment_files(_index, []), do: %{}

  defp load_fragment_files(index, fragments) do
    file_ids = fragments |> Enum.map(& &1.file_id) |> Enum.uniq()
    files_source = Schema.files_source(index.inverted.prefix)
    versions_source = Schema.package_versions_source(index.inverted.prefix)
    packages_source = Schema.packages_source(index.inverted.prefix)

    from(file in files_source,
      left_join: version in ^versions_source,
      on: version.id == file.package_version_id,
      left_join: package in ^packages_source,
      on: package.id == version.package_id,
      where: file.id in ^file_ids,
      select: {file.id, file.source, file.path, version.version, package.name, file.ast}
    )
    |> index.inverted.repo.all()
    |> Map.new(fn {file_id, source, path, package_version, package_name, file_ast} ->
      {file_id, {source, path, package_version, package_name, file_ast}}
    end)
  end

  defp hydrate_query_fragment(
         %FragmentRecord{} = fragment,
         source,
         path,
         package_version,
         package_name,
         file_ast,
         locator
       ) do
    Hydration.fragment(fragment, source, path, package_version, package_name, file_ast, locator)
  end

  defp hydrate_query_fragment(
         fragment,
         source,
         path,
         package_version,
         package_name,
         _file_ast,
         locator
       )
       when is_map(fragment) do
    %Fragment{
      id: fragment.id,
      package_id: fragment.package_id,
      package_version_id: fragment.package_version_id,
      package: package_name,
      package_version: package_version,
      file_id: fragment.file_id,
      file: path,
      source: source,
      ast: Exograph.AST.Locator.slice(locator, fragment.node_pre, fragment.node_post),
      node_pre: fragment.node_pre,
      node_post: fragment.node_post,
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
      fn -> {Keyword.get(opts, :cursor), false} end,
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
        FragmentStore.count(index.fragment_store)
      end),
      nil
    )
  end

  defp joined_fragments(index, %Plan{joins: [join]} = plan, opts, cursor) do
    joined_fragments_from_builder(index, plan, Keyword.put(opts, :cursor, cursor), [join])
  end

  defp joined_fragments(index, %Plan{joins: [_first, _second]} = plan, opts, _offset),
    do: joined_fragments_two(index, plan, opts)

  defp joined_fragments(index, %Plan{joins: [_first, _second, _third]} = plan, opts, _offset),
    do: joined_fragments_three(index, plan, opts)

  defp joined_fragments_two(index, %Plan{joins: [first_join, second_join]} = plan, opts) do
    joined_fragments_from_builder(index, plan, opts, [first_join, second_join])
  end

  defp joined_fragments_three(
         index,
         %Plan{joins: [first_join, second_join, third_join]} = plan,
         opts
       ) do
    joined_fragments_from_builder(index, plan, opts, [first_join, second_join, third_join])
  end

  defp joined_fragments_from_builder(index, plan, opts, joins) do
    rows =
      index
      |> then(fn index ->
        JoinBuilder.build(
          index,
          plan,
          Keyword.put(opts, :candidate_limit, candidate_limit(index, opts))
        )
        |> index.inverted.repo.all()
      end)

    records_by_assoc = joined_records(index, joins, rows)

    Enum.map(rows, fn row ->
      fragment =
        hydrate_joined_fragment(
          row.fragment,
          row.source,
          row.path,
          row.package_version,
          row.package,
          row.ast,
          index,
          plan
        )

      joined_by_binding =
        joins
        |> Enum.with_index(1)
        |> Map.new(fn {join, position} ->
          record =
            records_by_assoc
            |> Map.fetch!(join.assoc)
            |> Map.fetch!(join_id(row, position))

          {join.binding, joined_value(join.assoc, record)}
        end)

      {fragment, joined_by_binding}
    end)
  end

  defp joined_records(index, joins, rows) do
    joins
    |> Enum.map(& &1.assoc)
    |> Enum.uniq()
    |> Map.new(fn assoc ->
      ids =
        rows
        |> Enum.with_index()
        |> Enum.flat_map(fn {row, _row_position} ->
          joins
          |> Enum.with_index(1)
          |> Enum.filter(fn {join, _join_position} -> join.assoc == assoc end)
          |> Enum.map(fn {_join, join_position} -> join_id(row, join_position) end)
        end)
        |> Enum.uniq()

      records =
        case ids do
          [] ->
            []

          _ ->
            source = Sources.join_source(assoc, index.inverted.prefix)
            index.inverted.repo.all(from(record in source, where: record.id in ^ids))
        end

      {assoc, Map.new(records, &{&1.id, &1})}
    end)
  end

  defp join_id(row, 1), do: row.first_join_id
  defp join_id(row, 2), do: row.second_join_id
  defp join_id(row, 3), do: row.third_join_id

  defp definition_calls_join_all(index, plan, call_edge_binding, opts) do
    limit = Keyword.get(opts, :limit, 50)
    files_source = Schema.files_source(index.inverted.prefix)
    fragments_source = Schema.fragments_source(index.inverted.prefix)

    queryable =
      from(definition in Schema.definitions_source(index.inverted.prefix),
        join: edge in ^Schema.call_edges_source(index.inverted.prefix),
        on:
          edge.caller_qualified_name == definition.qualified_name and
            edge.package_version_id == definition.package_version_id,
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
      |> Enum.map(&hit(&1, Schema.definitions_source(index.inverted.prefix)))

    {:ok, results}
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

  defp hydrate_joined_fragment(
         fragment,
         source,
         path,
         package_version,
         package_name,
         file_ast,
         index,
         plan
       ) do
    if light_join_projection?(index, plan) do
      hydrate_light_fragment(fragment, source, path, package_version, package_name)
    else
      Hydration.fragment(fragment, source, path, package_version, package_name, file_ast)
    end
  end

  defp hydrate_light_fragment(record, source, path, package_version, package_name)
       when is_map(record) do
    %Fragment{
      id: record.id,
      package_id: record.package_id,
      package_version_id: record.package_version_id,
      package: package_name,
      package_version: package_version,
      file_id: record.file_id,
      file: path,
      source: source,
      node_pre: Map.get(record, :node_pre),
      node_post: Map.get(record, :node_post),
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
    files_source = Schema.files_source(index.inverted.prefix)
    versions_source = Schema.package_versions_source(index.inverted.prefix)
    fragments_source = Schema.fragments_source(index.inverted.prefix)

    from(fragment in {fragments_source, FragmentRecord},
      join: file in ^files_source,
      on: file.id == fragment.file_id,
      left_join: version in ^versions_source,
      on: version.id == fragment.package_version_id,
      where: fragment.id in ^ids,
      select: {fragment, file.source, file.path, version.version, file.ast}
    )
    |> index.inverted.repo.all()
    |> Map.new(fn {fragment, source, path, package_version, file_ast} ->
      hydrated = Hydration.fragment(fragment, source, path, package_version, nil, file_ast)
      {hydrated.id, hydrated}
    end)
  end

  defp structural_plan?(%Plan{structural_predicates: predicates}), do: predicates != []

  defp light_join_projection?(_index, %Plan{binding: binding, select: select} = plan)
       when select in [nil, binding] do
    not structural_plan?(plan)
  end

  defp light_join_projection?(_index, _plan), do: false

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
    files_source = Schema.files_source(index.inverted.prefix)
    fragments_source = Schema.fragments_source(index.inverted.prefix)

    from(fragment in {fragments_source, FragmentRecord},
      join: file in ^files_source,
      on: file.id == fragment.file_id,
      where: fragment.id in ^ids,
      select: {fragment.id, file.source, file.path}
    )
    |> index.inverted.repo.all()
    |> Map.new(fn {id, source, path} -> {id, {source, path}} end)
  end

  defp verify_fragment(fragment, verifier) do
    case verify_fragment_root(fragment, verifier) do
      {:ok, match} ->
        [Hit.with_match(Hit.new(fragment: fragment, score: 1.0), match)]

      :error ->
        []
    end
  end

  defp fragment_verifier(%Query{binding: binding, predicates: predicates}) do
    %{
      matches: predicates |> binding_patterns(binding, :matches) |> first_or_wildcard(),
      contains: binding_patterns(predicates, binding, :contains)
    }
  end

  defp binding_patterns(predicates, binding, kind) do
    Enum.flat_map(predicates, fn
      {^kind, ^binding, pattern} -> [pattern]
      _predicate -> []
    end)
  end

  defp first_or_wildcard([]), do: "_"
  defp first_or_wildcard([pattern | _rest]), do: pattern

  defp verify_fragment_root(fragment, %{matches: match_pattern, contains: contains_patterns}) do
    with {:ok, captures} <- ExAST.Pattern.match(fragment.ast, match_pattern),
         true <- Enum.all?(contains_patterns, &fragment_contains?(fragment, &1)) do
      {:ok, %{node: fragment.ast, captures: captures}}
    else
      _ -> :error
    end
  end

  defp fragment_contains?(%Fragment{} = fragment, pattern) when is_binary(pattern) do
    if Compiler.ast_pattern?(pattern) do
      fragment_contains_ast?(fragment, pattern)
    else
      fragment
      |> fragment_source_text()
      |> String.contains?(pattern)
    end
  end

  defp fragment_contains_ast?(%Fragment{} = fragment, pattern) do
    fragment.ast
    |> ExAST.Patcher.find_all(pattern)
    |> Enum.any?(fn %{node: node} -> node != fragment.ast end)
  rescue
    ArgumentError -> false
  end

  defp fragment_source_text(%Fragment{source: source, line: line, end_line: end_line})
       when is_binary(source) and is_integer(line) do
    lines = String.split(source, "\n", trim: false)
    start = max(line - 1, 0)
    count = fragment_source_line_count(line, end_line, length(lines), start)

    lines
    |> Enum.slice(start, count)
    |> Enum.join("\n")
  end

  defp fragment_source_text(_fragment), do: ""

  defp fragment_source_line_count(line, end_line, _line_count, _start)
       when is_integer(end_line) and end_line >= line,
       do: end_line - line + 1

  defp fragment_source_line_count(_line, _end_line, line_count, start),
    do: max(line_count - start, 0)

  defp joined_fragment_batch_limit(index, plan, opts) do
    if structural_plan?(plan) do
      @stream_batch_size
    else
      requested = Keyword.get(opts, :limit, 50) + Keyword.get(opts, :skip, 0)

      _index = index
      min(max(requested * 3, requested), @stream_batch_size)
    end
  end

  defp structural_fragment_candidate_limit(opts) do
    Keyword.get(opts, :candidate_limit, @stream_batch_size)
  end

  defp fragment_candidate_limit(%Plan{} = plan, opts) do
    if structural_plan?(plan), do: @stream_batch_size, else: fragment_candidate_limit(opts)
  end

  defp fragment_candidate_limit(opts) do
    requested = Keyword.get(opts, :limit, 50)
    min(max(requested * 3, requested), @stream_batch_size)
  end

  defp candidate_limit(index, opts) do
    Keyword.get_lazy(opts, :candidate_limit, fn ->
      FragmentStore.count(index.fragment_store)
    end)
  end

  defp predicates(%Plan{predicates_by_binding: predicates_by_binding}, binding) do
    Map.get(predicates_by_binding, binding, [])
  end

  defp entity_all(index, %Plan{source: :package} = plan, opts) do
    limit = Keyword.get(opts, :limit, 50)
    skip = Keyword.get(opts, :skip, 0)

    query =
      from(package in Sources.source(:package, index.inverted.prefix),
        order_by: [asc: package.id],
        offset: ^skip,
        limit: ^limit,
        select: package
      )
      |> where_source_predicates(predicates(plan, plan.binding), nil, :package)

    results =
      index.inverted.repo.all(query)
      |> Enum.map(fn package ->
        Exograph.Package.new(%{
          id: package.id,
          ecosystem: package.ecosystem,
          name: package.name,
          metadata: package.metadata || %{}
        })
      end)

    {:ok, results}
  end

  defp entity_all(index, %Plan{source: :package_version} = plan, opts) do
    limit = Keyword.get(opts, :limit, 50)
    skip = Keyword.get(opts, :skip, 0)
    packages = Sources.source(:package, index.inverted.prefix)

    query =
      from(version in Sources.source(:package_version, index.inverted.prefix),
        join: package in ^packages,
        on: package.id == version.package_id,
        order_by: [asc: version.id],
        offset: ^skip,
        limit: ^limit,
        select: {version, package.ecosystem, package.name}
      )
      |> where_source_predicates(predicates(plan, plan.binding), nil, :package_version)
      |> where_scope(opts)

    results =
      index.inverted.repo.all(query)
      |> Enum.map(fn {version, ecosystem, package_name} ->
        Exograph.PackageVersion.new(%{
          id: version.id,
          package_id: version.package_id,
          ecosystem: ecosystem,
          name: package_name,
          version: version.version,
          source_ref: version.source_ref,
          checksum: version.checksum,
          metadata: version.metadata || %{}
        })
      end)

    {:ok, results}
  end

  defp entity_all(index, %Plan{source: :file} = plan, opts) do
    limit = Keyword.get(opts, :limit, 50)
    skip = Keyword.get(opts, :skip, 0)

    query =
      from(file in Sources.source(:file, index.inverted.prefix),
        order_by: [asc: file.id],
        offset: ^skip,
        limit: ^limit,
        select: %{
          id: file.id,
          package_id: file.package_id,
          package_version_id: file.package_version_id,
          path: file.path,
          sha256: file.sha256
        }
      )
      |> where_source_predicates(predicates(plan, plan.binding), nil, :file)
      |> where_scope(opts)

    results = Enum.map(index.inverted.repo.all(query), &struct!(Exograph.FileRef, &1))
    {:ok, results}
  end

  defp symbol_fact_all(index, plan, opts, source_name) do
    source = Sources.source(source_name, index.inverted.prefix)
    limit = Keyword.get(opts, :limit, 50)
    skip = Keyword.get(opts, :skip, 0)
    files_source = Schema.files_source(index.inverted.prefix)
    fragments_source = Schema.fragments_source(index.inverted.prefix)

    query =
      from(fact in source,
        left_join: fragment in ^{fragments_source, FragmentRecord},
        on: fragment.id == fact.fragment_id,
        left_join: file in ^files_source,
        on: file.id == fragment.file_id,
        order_by: [asc: fact.qualified_name, asc: fact.line, asc: fact.id],
        offset: ^skip,
        limit: ^limit,
        select: {fact, fragment, nil, file.path, file.ast}
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
      from(edge in Schema.call_edges_source(index.inverted.prefix),
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

  defp hit({fact, fragment, source, path, file_ast}, {_table, DefinitionRecord}) do
    DefinitionHit.new(
      definition: DefinitionRecord.to_definition(fact),
      fragment: hydrate_fragment(fragment, source, path, file_ast),
      score: 1.0
    )
  end

  defp hit({fact, fragment, source, path, file_ast}, {_table, ReferenceRecord}) do
    ReferenceHit.new(
      reference: ReferenceRecord.to_reference(fact),
      fragment: hydrate_fragment(fragment, source, path, file_ast),
      score: 1.0
    )
  end

  defp hydrate_fragment(nil, _source, _path, _file_ast), do: nil

  defp hydrate_fragment(fragment, source, path, file_ast),
    do: Hydration.fragment(fragment, source, path, nil, nil, file_ast)
end
