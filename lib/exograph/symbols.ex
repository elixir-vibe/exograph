defmodule Exograph.Symbols do
  @moduledoc false

  alias Exograph.Ident

  @type result :: %{
          defs: MapSet.t(String.t()),
          refs: MapSet.t(String.t()),
          modules: MapSet.t(String.t()),
          functions: MapSet.t(String.t()),
          aliases: MapSet.t(String.t()),
          structs: MapSet.t(String.t()),
          atoms: MapSet.t(String.t())
        }

  @spec extract(Macro.t()) :: result()
  def extract(ast) do
    {_ast, acc} = Macro.prewalk(ast, empty(), &visit/2)
    acc
  end

  defp empty do
    %{
      defs: MapSet.new(),
      refs: MapSet.new(),
      modules: MapSet.new(),
      functions: MapSet.new(),
      aliases: MapSet.new(),
      structs: MapSet.new(),
      atoms: MapSet.new()
    }
  end

  defp visit({:defmodule, _, [module_ast | _]} = node, acc) do
    case alias_name(module_ast) do
      nil -> {node, acc}
      module -> {node, acc |> put(:defs, module) |> put(:modules, module)}
    end
  end

  defp visit({form, _, [head | _]} = node, acc)
       when form in [:def, :defp, :defmacro, :defmacrop] do
    case function_head(head) do
      {name, arity} ->
        {node, acc |> put(:defs, "#{name}/#{arity}") |> put(:functions, name)}

      nil ->
        {node, acc}
    end
  end

  defp visit({:alias, _, args} = node, acc) when is_list(args) do
    aliases = args |> List.flatten() |> Enum.flat_map(&aliases_from/1)
    {node, Enum.reduce(aliases, acc, &put(&2, :aliases, &1))}
  end

  defp visit({:%, _, [struct_ast | _]} = node, acc) do
    case alias_name(struct_ast) do
      nil -> {node, acc}
      struct -> {node, put(acc, :structs, struct)}
    end
  end

  defp visit({{:., _, [module_ast, fun]}, _, args} = node, acc) when is_list(args) do
    if identifier?(fun) do
      fun = identifier_name(fun)

      case alias_name(module_ast) do
        nil -> {node, put(acc, :refs, "#{fun}/#{length(args)}")}
        module -> {node, put(acc, :refs, "#{module}.#{fun}/#{length(args)}")}
      end
    else
      {node, acc}
    end
  end

  defp visit({name, _, args} = node, acc) when is_list(args) do
    if identifier?(name) and not synthetic_call?(name) do
      {node, put(acc, :refs, "#{identifier_name(name)}/#{length(args)}")}
    else
      {node, acc}
    end
  end

  defp visit({:__exograph_ident__, _name} = node, acc), do: {node, acc}

  defp visit({:__aliases__, _, _} = node, acc) do
    case alias_name(node) do
      nil -> {node, acc}
      alias -> {node, put(acc, :aliases, alias)}
    end
  end

  defp visit(atom, acc) when is_atom(atom) and atom not in [nil, true, false] do
    {atom, put(acc, :atoms, Atom.to_string(atom))}
  end

  defp visit(node, acc), do: {node, acc}

  defp function_head({:when, _, [head | _]}), do: function_head(head)

  defp function_head({name, _, nil}) do
    if identifier?(name), do: {identifier_name(name), 0}, else: nil
  end

  defp function_head({name, _, args}) when is_list(args) do
    if identifier?(name), do: {identifier_name(name), length(args)}, else: nil
  end

  defp function_head(_), do: nil

  defp aliases_from({:__aliases__, _, _} = ast), do: [alias_name(ast)]

  defp aliases_from({{:., _, [base, :{}]}, _, grouped}) when is_list(grouped) do
    base = alias_name(base)

    if base do
      Enum.flat_map(grouped, fn item ->
        case alias_name(item) do
          nil -> []
          suffix -> [base <> "." <> suffix]
        end
      end)
    else
      []
    end
  end

  defp aliases_from(_), do: []

  defp alias_name({:__aliases__, _, parts}) when is_list(parts) do
    if Enum.all?(parts, &identifier?/1),
      do: parts |> Enum.map(&identifier_name/1) |> Enum.join("."),
      else: nil
  end

  defp alias_name(_), do: nil

  defp identifier?(value), do: is_atom(value) or Ident.ident?(value)

  defp identifier_name(value) when is_atom(value), do: Atom.to_string(value)
  defp identifier_name(value), do: Ident.name(value)

  defp synthetic_call?(name) when is_atom(name), do: name in [:__aliases__, :., :..., :_]
  defp synthetic_call?(_name), do: false

  defp put(acc, _key, nil), do: acc

  defp put(acc, key, value) when is_binary(value),
    do: Map.update!(acc, key, &MapSet.put(&1, value))
end
