defmodule Exograph.Web.SearchResult do
  @moduledoc false

  @unknown_atom "__exograph_unknown_atom__"
  @definition_kinds [:def, :defp, :defmacro, :defmacrop]

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
    :package_version
  ]

  def from(%Exograph.Hit{fragment: f, match: m}) do
    match = match_attrs(m)

    %__MODULE__{
      type: :fragment,
      file: relative_path(f.file),
      package: extract_package(f.file),
      module: clean_name(f.module),
      kind: match.kind || f.kind,
      name: clean_name(match.name || f.name),
      arity: match.arity || f.arity,
      line: match.line || f.line,
      source: f.source,
      fragment_line: f.line,
      joined_label: nil,
      preview: nil,
      package_version: extract_package_version(f.file)
    }
  end

  def from(%Exograph.TextHit{fragment: f}) do
    %__MODULE__{
      type: :text,
      file: relative_path(f.file),
      package: extract_package(f.file),
      module: clean_name(f.module),
      kind: f.kind,
      name: clean_name(f.name),
      arity: f.arity,
      line: f.line,
      source: f.source,
      fragment_line: f.line,
      joined_label: nil,
      preview: nil,
      package_version: extract_package_version(f.file)
    }
  end

  def from({%Exograph.Hit{fragment: f, match: m}, joined}) do
    match = match_attrs(m)

    %__MODULE__{
      type: :joined,
      file: relative_path(f.file),
      package: extract_package(f.file),
      module: clean_name(f.module),
      kind: match.kind || f.kind,
      name: clean_name(match.name || f.name),
      arity: match.arity || f.arity,
      line: match.line || f.line,
      source: f.source,
      fragment_line: f.line,
      joined_label: format_joined(joined),
      preview: nil,
      package_version: extract_package_version(f.file)
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
      file: file,
      package: extract_package(file),
      module: clean_name(d.module),
      kind: d.kind,
      name: clean_name(d.qualified_name),
      arity: d.arity,
      line: d.line,
      source: if(f, do: f.source, else: nil),
      fragment_line: if(f, do: f.line, else: nil),
      joined_label: nil,
      preview: nil,
      package_version: extract_package_version(file)
    }
  end

  def from(%Exograph.ReferenceHit{reference: r, fragment: f}) do
    file = if f, do: f.file || "", else: ""

    %__MODULE__{
      type: :reference,
      file: file,
      package: extract_package(file),
      module: clean_name(r.module),
      kind: r.kind,
      name: clean_name(r.qualified_name),
      arity: r.arity,
      line: r.line,
      source: if(f, do: f.source, else: nil),
      fragment_line: if(f, do: f.line, else: nil),
      joined_label: nil,
      preview: nil,
      package_version: extract_package_version(file)
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
  defp match_attrs(%{line: line}), do: %{kind: nil, name: nil, arity: nil, line: line}
  defp match_attrs(_match), do: %{kind: nil, name: nil, arity: nil, line: nil}

  defp node_attrs({kind, meta, args}) when kind in @definition_kinds and is_list(args) do
    {name, arity} = args |> List.first() |> definition_head_name_arity()
    %{kind: kind, name: name, arity: arity, line: Keyword.get(meta, :line)}
  end

  defp node_attrs({:defmodule, meta, args}) when is_list(args) do
    %{
      kind: :module,
      name: module_name(List.first(args)),
      arity: nil,
      line: Keyword.get(meta, :line)
    }
  end

  defp node_attrs({kind, meta, _args}) when is_atom(kind) and is_list(meta) do
    %{kind: kind, name: nil, arity: nil, line: Keyword.get(meta, :line)}
  end

  defp node_attrs(_node), do: %{kind: nil, name: nil, arity: nil, line: nil}

  defp definition_head_name_arity({:when, _meta, [head | _guards]}),
    do: definition_head_name_arity(head)

  defp definition_head_name_arity({name, _meta, args}) when is_atom(name) and is_list(args),
    do: {Atom.to_string(name), length(args)}

  defp definition_head_name_arity({name, _meta, nil}) when is_atom(name),
    do: {Atom.to_string(name), 0}

  defp definition_head_name_arity(_head), do: {nil, nil}

  defp module_name({:__aliases__, _meta, parts}) when is_list(parts),
    do: Enum.map_join(parts, ".", &to_string/1)

  defp module_name(atom) when is_atom(atom), do: Atom.to_string(atom)
  defp module_name(_other), do: nil

  defp clean_name(nil), do: nil
  defp clean_name(name) when is_atom(name), do: clean_name(Atom.to_string(name))

  defp clean_name(name) when is_binary(name) do
    if String.contains?(name, @unknown_atom), do: nil, else: name
  end

  defp relative_path(nil), do: ""

  defp relative_path(path) do
    case Regex.run(~r"/sources/[^/]+/(.+)$", path) do
      [_, rel] -> rel
      _ -> Path.basename(path)
    end
  end

  defp extract_package(nil), do: "unknown"
  defp extract_package(""), do: "unknown"

  defp extract_package(file) do
    case Regex.run(~r"/sources/([^/]+)/", file) do
      [_, pkg_dir] ->
        case Regex.run(~r/^(.+)-\d/, pkg_dir) do
          [_, name] -> name
          _ -> pkg_dir
        end

      _ ->
        file |> Path.basename() |> Path.rootname()
    end
  end

  defp extract_package_version(nil), do: nil
  defp extract_package_version(""), do: nil

  defp extract_package_version(file) do
    case Regex.run(~r"/sources/([^/]+)/", file) do
      [_, pkg_dir] ->
        case Regex.run(~r/^.+-(\d+\.\d+\.\d+.*)$/, pkg_dir) do
          [_, version] -> version
          _ -> nil
        end

      _ ->
        nil
    end
  end
end
