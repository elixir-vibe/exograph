defmodule Exograph.Extractor.Reach do
  @moduledoc """
  Extracts Reach semantic facts from source files.

  The first persisted layer is the call graph: local function nodes, external
  callee nodes, and call edges with stable Exograph IDs.
  """

  alias Exograph.{CallEdge, FragmentLocator, GraphNode, Ident}

  def extract_files(files, fragments_by_file) do
    if Code.ensure_loaded?(Reach) do
      do_extract_files(files, fragments_by_file)
    else
      %{graph_nodes: [], call_edges: []}
    end
  end

  defp do_extract_files(files, fragments_by_file) do
    files
    |> Enum.map(&extract_file(&1, Map.get(fragments_by_file, &1.id, [])))
    |> Enum.reduce(%{graph_nodes: [], call_edges: []}, fn facts, acc ->
      %{
        graph_nodes: [facts.graph_nodes | acc.graph_nodes],
        call_edges: [facts.call_edges | acc.call_edges]
      }
    end)
    |> Map.update!(:graph_nodes, fn nodes ->
      nodes |> List.flatten() |> Enum.uniq_by(&external_key/1)
    end)
    |> Map.update!(:call_edges, fn edges -> List.flatten(edges) end)
  end

  defp external_key(%GraphNode{external_id: ext, qualified_name: qn, kind: kind}) do
    {ext, qn, kind}
  end

  defp extract_file(file, fragments) do
    with {:ok, ast} <-
           Code.string_to_quoted(file.source,
             columns: true,
             file: file.path,
             emit_warnings: false
           ),
         {:ok, graph} <- Reach.ast_to_graph(ast, file: file.path) do
      definitions = function_definitions(file.source)
      local_nodes = local_nodes(file, fragments, definitions, graph)

      local_by_mfa =
        Map.new(local_nodes, &{mfa_key(&1), &1})
        |> Map.merge(Map.new(local_nodes, &{{nil, &1.name, &1.arity}, &1}))

      {nodes, edges} =
        graph.call_graph
        |> Graph.edges()
        |> Enum.reject(&internal_call?/1)
        |> Enum.reduce({local_nodes, []}, fn edge, {nodes, edges} ->
          call_node = call_node(graph, edge)
          caller = local_by_mfa[mfa_key(edge.v1)]

          callee =
            local_by_mfa[mfa_key(edge.v2)] ||
              callee_node(file, fragments, edge.v2, call_node, caller)

          if caller && callee do
            edge = call_edge(file, fragments, caller, callee, call_node)
            {[callee | nodes], [edge | edges]}
          else
            {nodes, edges}
          end
        end)

      %{graph_nodes: Enum.uniq_by(nodes, &external_key/1), call_edges: edges}
    else
      _ -> %{graph_nodes: [], call_edges: []}
    end
  end

  defp function_definitions(source) do
    source
    |> ExAST.Symbols.definitions()
    |> Enum.filter(&(&1.kind in [:def, :defp, :defmacro, :defmacrop]))
    |> Map.new(fn definition -> {{definition.name, definition.arity}, definition} end)
  rescue
    _ -> %{}
  end

  defp local_nodes(file, fragments, definitions, graph) do
    graph
    |> Reach.nodes(type: :function_def)
    |> Enum.map(fn node ->
      name = node.meta[:name]
      arity = node.meta[:arity]
      definition = definitions[{function_name(name), arity}]
      line = source_line(node) || maybe_field(definition, :line)
      column = source_column(node) || maybe_field(definition, :column)
      module = maybe_field(definition, :module)

      qualified_name =
        maybe_field(definition, :qualified_name) || qualified_name(module, name, arity)

      graph_node(file,
        file_id: file.id,
        fragment_id: FragmentLocator.containing_fragment_id(fragments, line),
        external_id: reach_node_id(node),
        kind: :function,
        module: module,
        name: function_name(name),
        arity: arity,
        qualified_name: qualified_name,
        line: line,
        column: column,
        metadata: %{visibility: maybe_field(definition, :visibility), reach_type: node.type}
      )
    end)
  end

  defp callee_node(file, fragments, {nil, name, arity}, call_node, caller) do
    module = caller && caller.module
    line = source_line(call_node)
    column = source_column(call_node)

    graph_node(file,
      file_id: file.id,
      fragment_id: FragmentLocator.containing_fragment_id(fragments, line),
      external_id: reach_node_id(call_node),
      kind: :function,
      module: module,
      name: function_name(name),
      arity: arity,
      qualified_name: qualified_name(module, name, arity),
      line: line,
      column: column,
      metadata: %{reach_type: call_node && call_node.type, local_call?: true}
    )
  end

  defp callee_node(file, _fragments, {module, name, arity}, call_node, _caller) do
    module = module_name(module)

    graph_node(file,
      file_id: nil,
      fragment_id: nil,
      external_id: external_id(module, name, arity),
      kind: :external_function,
      module: module,
      name: function_name(name),
      arity: arity,
      qualified_name: qualified_name(module, name, arity),
      line: nil,
      column: nil,
      metadata: %{reach_type: call_node && call_node.type, external?: true}
    )
  end

  defp graph_node(file, attrs) do
    attrs
    |> Keyword.merge(package_id: file.package_id, package_version_id: file.package_version_id)
    |> GraphNode.new()
  end

  defp call_edge(file, fragments, caller, callee, call_node) do
    line = source_line(call_node)
    column = source_column(call_node)

    CallEdge.new(%{
      package_id: file.package_id,
      package_version_id: file.package_version_id,
      file_id: file.id,
      caller_node_id: caller.id,
      callee_node_id: callee.id,
      call_site_fragment_id: FragmentLocator.containing_fragment_id(fragments, line),
      caller_qualified_name: caller.qualified_name,
      callee_qualified_name: callee.qualified_name,
      line: line,
      column: column,
      metadata: %{reach_call_node_id: call_node && call_node.id}
    })
  end

  defp call_node(graph, %{label: {:call, node_id}}), do: Reach.node(graph, node_id)
  defp call_node(_graph, _edge), do: nil

  defp internal_call?(%{v2: {_module, :__aliases__, _arity}}), do: true
  defp internal_call?(%{v2: {_module, :__block__, _arity}}), do: true
  defp internal_call?(_edge), do: false

  defp mfa_key(%GraphNode{module: module, name: name, arity: arity}), do: {module, name, arity}
  defp mfa_key({_module, name, arity}), do: {nil, function_name(name), arity}

  defp source_line(nil), do: nil
  defp source_line(%{source_span: nil}), do: nil
  defp source_line(%{source_span: span}), do: span[:start_line]

  defp source_column(nil), do: nil
  defp source_column(%{source_span: nil}), do: nil
  defp source_column(%{source_span: span}), do: span[:start_col]

  defp maybe_field(nil, _field), do: nil
  defp maybe_field(struct, field), do: Map.get(struct, field)

  defp module_name(module) when is_atom(module),
    do: Atom.to_string(module) |> String.trim_leading("Elixir.")

  defp module_name(module), do: term_name(module)

  defp function_name(name), do: term_name(name)

  defp qualified_name(nil, name, arity), do: "#{function_name(name)}/#{arity}"
  defp qualified_name(module, name, arity), do: "#{module}.#{function_name(name)}/#{arity}"

  defp term_name(value) when is_atom(value), do: Atom.to_string(value)
  defp term_name(value) when is_binary(value), do: value

  defp term_name(value) when is_tuple(value) do
    if Ident.ident?(value), do: Ident.name(value), else: Macro.to_string(value)
  end

  defp term_name(value), do: to_string(value)

  defp reach_node_id(nil), do: nil
  defp reach_node_id(%{id: id}), do: to_string(id)

  defp external_id(module, name, arity), do: "#{module}.#{name}/#{arity}"
end
