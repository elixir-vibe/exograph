defmodule Exograph.Web.Completion do
  @moduledoc false

  alias Exograph.Storage.Schema

  # imported for @eval_env to capture DSL macros
  import Exograph.DSL, warn: false
  @eval_env __ENV__

  @dsl_sources [
    {"Fragment", "Exograph DSL source — structural code fragments"},
    {"Definition", "Exograph DSL source — function/macro definitions"},
    {"Reference", "Exograph DSL source — symbol references"},
    {"CallEdge", "Exograph DSL source — call graph edges"}
  ]

  def complete(hint, index) do
    items = elixir_completions(hint) ++ index_completions(hint, index)

    items
    |> Enum.uniq_by(& &1.label)
    |> Enum.sort_by(& &1.label)
  end

  defp elixir_completions(hint) do
    case Code.Fragment.cursor_context(hint) do
      {:alias, alias} ->
        complete_alias(List.to_string(alias))

      {:dot, path, member} ->
        complete_dot(path, List.to_string(member))

      {:local_or_var, local} ->
        complete_local(List.to_string(local))

      {:local_call, _} ->
        []

      :expr ->
        complete_local("")

      _ ->
        []
    end
  end

  defp complete_alias(hint) do
    case split_last_dot(hint) do
      {prefix, suffix} ->
        mod = expand_alias(prefix)
        complete_child_modules(mod, suffix)

      nil ->
        dsl_sources(hint) ++ complete_root_modules(hint) ++ complete_env_aliases(hint)
    end
  end

  defp dsl_sources(hint) do
    for {name, detail} <- @dsl_sources,
        String.starts_with?(name, hint),
        do: item(name, "module", detail)
  end

  @allowed_root_modules ~w(
    Atom Enum Integer Keyword List Map MapSet Range Regex Stream String Tuple
    Exograph
  )

  defp complete_root_modules(hint) do
    for name <- @allowed_root_modules,
        String.starts_with?(name, hint),
        do: item(name, "module", module_detail(Module.concat([name])))
  end

  defp complete_env_aliases(hint) do
    for {alias_mod, _target} <- @eval_env.aliases,
        [name] = Module.split(alias_mod),
        String.starts_with?(name, hint),
        do: item(name, "module", "alias")
  end

  defp complete_child_modules(base, hint) do
    prefix = "#{base}.#{hint}"
    depth = prefix |> Module.split() |> length()

    for mod <- all_modules(),
        String.starts_with?(Atom.to_string(mod), prefix),
        parts = Module.split(mod),
        length(parts) >= depth,
        name = module_part(parts, depth - 1),
        child = parts |> Enum.take(depth) |> Module.concat(),
        uniq: true,
        do: item(name, "module", module_detail(child))
  end

  defp complete_dot(path, hint) do
    case expand_dot_path(path) do
      {:ok, mod} when is_atom(mod) ->
        complete_module_members(mod, hint)

      _ ->
        []
    end
  end

  defp complete_module_members(mod, hint) do
    if Code.ensure_loaded?(mod) do
      funs =
        try do
          mod.__info__(:functions) ++ mod.__info__(:macros)
        rescue
          ArgumentError -> []
        end

      for {name, arity} <- funs,
          name_str = Atom.to_string(name),
          String.starts_with?(name_str, hint),
          not String.starts_with?(name_str, "__"),
          do:
            item("#{name}/#{arity}", "function", function_detail(mod, name, arity),
              insert_text: name_str
            )
    else
      []
    end
  end

  defp complete_local(hint) do
    imports =
      for {mod, funs} <- @eval_env.functions ++ @eval_env.macros,
          {name, arity} <- funs,
          name_string = Atom.to_string(name),
          String.starts_with?(name_string, hint),
          not String.starts_with?(name_string, "__"),
          do:
            item("#{name}/#{arity}", "function", function_detail(mod, name, arity),
              insert_text: name_string
            )

    imports ++ complete_special_forms(hint)
  end

  defp complete_special_forms(hint) do
    for {name, arity} <- Kernel.SpecialForms.__info__(:macros),
        name_string = Atom.to_string(name),
        String.starts_with?(name_string, hint),
        do: item("#{name}/#{arity}", "function", "Kernel.SpecialForms", insert_text: name_string)
  end

  defp expand_dot_path({:var, _var}), do: :error
  defp expand_dot_path({:alias, alias}), do: expand_alias(List.to_string(alias))
  defp expand_dot_path({:unquoted_atom, _atom}), do: :error

  defp expand_dot_path({:dot, parent, call}) do
    with {:ok, mod} <- expand_dot_path(parent) do
      find_known_module(Module.split(mod) ++ [List.to_string(call)])
    end
  end

  defp expand_alias(alias) do
    case String.split(alias, ".", trim: true) do
      [] ->
        :error

      [first | rest] ->
        case Enum.find(@eval_env.aliases, fn {alias_mod, _resolved} ->
               Module.split(alias_mod) == [first]
             end) do
          {_alias_mod, resolved} -> find_known_module(Module.split(resolved) ++ rest)
          nil -> find_known_module([first | rest])
        end
    end
  end

  defp find_known_module(parts) do
    case Enum.find(all_modules(), &(Module.split(&1) == parts)) do
      nil -> :error
      module -> {:ok, module}
    end
  end

  defp index_completions(hint, index) do
    cond do
      String.match?(hint, ~r/qualified_name\s*==\s*"[^"]*$/) ->
        suggest_from_db(index, :references, :qualified_name, extract_partial(hint))

      String.match?(hint, ~r/callee_qualified_name\s*==\s*"[^"]*$/) ->
        suggest_from_db(index, :call_edges, :callee_qualified_name, extract_partial(hint))

      String.match?(hint, ~r/module\s*==\s*"[^"]*$/) ->
        suggest_from_db(index, :modules, :module, extract_partial(hint))

      true ->
        []
    end
  end

  defp suggest_from_db(index, source, field, partial) do
    prefix = index.inverted.prefix
    repo = index.inverted.repo

    {queryable, column} =
      case {source, field} do
        {:references, :qualified_name} ->
          {Schema.references_source(prefix), :qualified_name}

        {:call_edges, :callee_qualified_name} ->
          {Schema.call_edges_source(prefix), :callee_qualified_name}

        {:modules, :module} ->
          {Schema.source(:fragments, prefix), :module}
      end

    require Ecto.Query

    query =
      Ecto.Query.from(r in queryable,
        where: ilike(field(r, ^column), ^"#{partial}%"),
        group_by: field(r, ^column),
        order_by: [desc: count()],
        limit: 15,
        select: field(r, ^column)
      )

    query =
      if source == :modules,
        do: Ecto.Query.where(query, [r], not is_nil(field(r, ^column))),
        else: query

    repo.all(query, timeout: 10_000)
    |> Enum.map(fn name -> item(name, "variable", "#{source}") end)
  rescue
    QuackDB.Error -> []
  end

  defp extract_partial(hint) do
    case Regex.run(~r/"([^"]*)$/, hint) do
      [_, partial] -> partial
      _ -> ""
    end
  end

  defp item(label, kind, detail, opts \\ []) do
    %{
      label: label,
      kind: kind,
      detail: detail,
      insert_text: Keyword.get(opts, :insert_text, label)
    }
  end

  defp function_detail(mod, name, arity) do
    mod_name = module_name(mod)
    doc = fetch_function_doc(mod, name, arity)
    if doc, do: "#{mod_name} — #{doc}", else: mod_name
  end

  defp fetch_function_doc(mod, name, arity) do
    case Code.fetch_docs(mod) do
      {:docs_v1, _, _, _format, _, _, docs} ->
        Enum.find_value(docs, fn
          {{_, ^name, ^arity}, _, _, %{"en" => doc}, _} ->
            doc |> first_paragraph() |> String.trim()

          _ ->
            nil
        end)

      _ ->
        nil
    end
  rescue
    ArgumentError -> nil
  end

  defp module_detail(mod) do
    case Code.fetch_docs(mod) do
      {:docs_v1, _, _, _, %{"en" => doc}, _, _} ->
        doc |> first_paragraph() |> String.trim()

      _ ->
        "module"
    end
  rescue
    ArgumentError -> "module"
  end

  defp module_part(parts, index), do: parts |> Enum.drop(index) |> hd()

  defp module_name(mod) do
    case Atom.to_string(mod) do
      "Elixir." <> name -> name
      name -> name
    end
  end

  defp first_paragraph(doc), do: doc |> String.split("\n\n", parts: 2) |> hd()

  defp split_last_dot(string) do
    case :binary.matches(string, ".") do
      [] ->
        nil

      parts ->
        {pos, _} = List.last(parts)
        {binary_part(string, 0, pos), binary_part(string, pos + 1, byte_size(string) - pos - 1)}
    end
  end

  defp all_modules do
    modules = Enum.map(:code.all_loaded(), &elem(&1, 0))

    extra =
      if :code.get_mode() == :interactive do
        for [app] <- :ets.match(:ac_tab, {{:loaded, :"$1"}, :_}),
            {:ok, mods} = :application.get_key(app, :modules),
            mod <- mods,
            do: mod
      else
        []
      end

    (modules ++ extra)
    |> Enum.filter(&elixir_module?/1)
    |> Enum.uniq()
  end

  defp elixir_module?(mod), do: mod |> Atom.to_string() |> String.starts_with?("Elixir.")
end
