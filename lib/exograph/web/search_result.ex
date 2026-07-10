defmodule Exograph.Web.SearchResult do
  @moduledoc false

  alias Exograph.Ident

  @definition_kinds [:def, :defp, :defmacro, :defmacrop]

  defmodule MatchAttrs do
    @moduledoc false
    defstruct kind: nil, name: nil, arity: nil, line: nil
  end

  defstruct [
    :type,
    :file,
    :package,
    :module,
    :kind,
    :name,
    :arity,
    :line,
    :source,
    :fragment_line,
    :joined_label,
    :preview,
    :package_version,
    :source_url
  ]

  def from(%Exograph.Hit{fragment: f, match: m}) do
    match = match_attrs(m)

    %__MODULE__{
      type: :fragment,
      file: relative_path(f.file),
      package: fragment_package(f),
      module: clean_name(f.module),
      kind: match.kind || f.kind,
      name: clean_name(match.name || f.name),
      arity: match.arity || f.arity,
      line: match.line || f.line,
      source: f.source,
      fragment_line: f.line,
      joined_label: nil,
      preview: nil,
      package_version: fragment_package_version(f)
    }
  end

  def from(%Exograph.TextHit{fragment: f}) do
    %__MODULE__{
      type: :text,
      file: relative_path(f.file),
      package: fragment_package(f),
      module: clean_name(f.module),
      kind: f.kind,
      name: clean_name(f.name),
      arity: f.arity,
      line: f.line,
      source: f.source,
      fragment_line: f.line,
      joined_label: nil,
      preview: nil,
      package_version: fragment_package_version(f)
    }
  end

  def from({%Exograph.Hit{fragment: f, match: m}, joined}) do
    match = match_attrs(m)

    %__MODULE__{
      type: :joined,
      file: relative_path(f.file),
      package: fragment_package(f),
      module: clean_name(f.module),
      kind: match.kind || f.kind,
      name: clean_name(match.name || f.name),
      arity: match.arity || f.arity,
      line: match.line || f.line,
      source: f.source,
      fragment_line: f.line,
      joined_label: format_joined(joined),
      preview: nil,
      package_version: fragment_package_version(f)
    }
  end

  def from({%Exograph.Hit{} = hit, j1, j2}) do
    result = from({hit, j1})

    joined =
      [result.joined_label, inspect(j2, limit: 60)]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(", ")

    %{result | joined_label: joined}
  end

  def from({%Exograph.Hit{} = hit, j1, j2, j3}) do
    result = from({hit, j1})

    joined =
      [result.joined_label, inspect(j2, limit: 40), inspect(j3, limit: 40)]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(", ")

    %{result | joined_label: joined}
  end

  def from(%Exograph.DefinitionHit{definition: d, fragment: f}) do
    file = if f, do: f.file || "", else: ""

    %__MODULE__{
      type: :definition,
      file: relative_path(file),
      package: fragment_package(f),
      module: clean_name(d.module),
      kind: d.kind,
      name: clean_name(d.qualified_name),
      arity: d.arity,
      line: d.line,
      source: if(f, do: f.source, else: nil),
      fragment_line: if(f, do: f.line, else: nil),
      joined_label: nil,
      preview: nil,
      package_version: if(f, do: fragment_package_version(f), else: nil)
    }
  end

  def from(%Exograph.ReferenceHit{reference: r, fragment: f}) do
    file = if f, do: f.file || "", else: ""

    %__MODULE__{
      type: :reference,
      file: relative_path(file),
      package: fragment_package(f),
      module: clean_name(r.module),
      kind: r.kind,
      name: clean_name(r.qualified_name),
      arity: r.arity,
      line: r.line,
      source: if(f, do: f.source, else: nil),
      fragment_line: if(f, do: f.line, else: nil),
      joined_label: nil,
      preview: nil,
      package_version: if(f, do: fragment_package_version(f), else: nil)
    }
  end

  def from(%Exograph.CallEdgeHit{call_edge: e}) do
    %__MODULE__{
      type: :call_edge,
      file: "",
      package: "call_edges",
      module: nil,
      kind: :call,
      name: "#{e.caller_qualified_name} → #{e.callee_qualified_name}",
      arity: nil,
      line: e.line,
      source: nil,
      fragment_line: nil,
      joined_label: nil,
      preview: nil,
      package_version: nil
    }
  end

  def from(tuple) when is_tuple(tuple) do
    case Tuple.to_list(tuple) do
      [%Exograph.Hit{} = hit | rest] -> from({hit, List.first(rest)})
      _ -> unknown_result(inspect(tuple, limit: 200))
    end
  end

  def from(other), do: unknown_result(inspect(other, limit: 200))

  defp unknown_result(label) do
    %__MODULE__{
      type: :unknown,
      file: "",
      package: "unknown",
      module: nil,
      kind: nil,
      name: label,
      arity: nil,
      line: nil,
      source: nil,
      fragment_line: nil,
      joined_label: nil,
      preview: nil,
      package_version: nil
    }
  end

  defp format_joined(%Exograph.Definition{} = d), do: "def #{d.qualified_name}"
  defp format_joined(%Exograph.Reference{} = r), do: "ref #{r.qualified_name}"

  defp format_joined(%Exograph.CallEdge{} = e),
    do: "#{e.caller_qualified_name} → #{e.callee_qualified_name}"

  defp format_joined(_), do: nil

  defp match_attrs(%{node: node}), do: node_attrs(node)
  defp match_attrs(%{line: line}), do: %MatchAttrs{line: line}
  defp match_attrs(_match), do: %MatchAttrs{}

  defp node_attrs({kind, meta, args}) when kind in @definition_kinds and is_list(args) do
    {name, arity} = args |> List.first() |> definition_head_name_arity()
    %MatchAttrs{kind: kind, name: name, arity: arity, line: Keyword.get(meta, :line)}
  end

  defp node_attrs({:defmodule, meta, args}) when is_list(args) do
    %MatchAttrs{
      kind: :module,
      name: module_name(List.first(args)),
      line: Keyword.get(meta, :line)
    }
  end

  defp node_attrs({kind, meta, _args}) when is_atom(kind) and is_list(meta) do
    %MatchAttrs{kind: kind, line: Keyword.get(meta, :line)}
  end

  defp node_attrs(_node), do: %MatchAttrs{}

  defp definition_head_name_arity({:when, _meta, [head | _guards]}),
    do: definition_head_name_arity(head)

  defp definition_head_name_arity({name, _meta, args}) when is_list(args) do
    if identifier?(name), do: {identifier_name(name), length(args)}, else: {nil, nil}
  end

  defp definition_head_name_arity({name, _meta, nil}) do
    if identifier?(name), do: {identifier_name(name), 0}, else: {nil, nil}
  end

  defp definition_head_name_arity(_head), do: {nil, nil}

  defp module_name({:__aliases__, _meta, parts}) when is_list(parts) do
    if Enum.all?(parts, &identifier?/1),
      do: Enum.map_join(parts, ".", &identifier_name/1),
      else: nil
  end

  defp module_name(atom) when is_atom(atom), do: Atom.to_string(atom)
  defp module_name(ident), do: if(Ident.ident?(ident), do: Ident.name(ident), else: nil)

  defp clean_name(nil), do: nil
  defp clean_name(name) when is_atom(name), do: clean_name(Atom.to_string(name))
  defp clean_name(name) when is_binary(name), do: name

  defp identifier?(value), do: is_atom(value) or Ident.ident?(value)

  defp identifier_name(value) when is_atom(value), do: Atom.to_string(value)
  defp identifier_name(value), do: Ident.name(value)

  defp relative_path(nil), do: ""
  defp relative_path(path) when is_binary(path), do: path

  defp fragment_package(%{package: package}) when is_binary(package), do: package
  defp fragment_package(_fragment), do: "unknown"

  defp fragment_package_version(%{package_version: version}) when is_binary(version), do: version
  defp fragment_package_version(_fragment), do: nil
end
