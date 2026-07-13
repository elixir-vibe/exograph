defmodule Exograph.DSL.Compiler do
  @moduledoc false

  alias Exograph.Query
  alias Exograph.Query.Predicate

  @spec from_pattern(ExAST.Pattern.pattern() | ExAST.Selector.t()) :: Query.t()
  def from_pattern(pattern) when is_binary(pattern) do
    %Query{
      source: :fragment,
      binding: "f",
      predicates: [%Predicate{op: :matches, binding: "f", value: pattern}]
    }
  end

  @spec from_selector(ExAST.Selector.t()) :: Query.t()
  def from_selector(%ExAST.Selector{steps: [{:self, ast}]} = selector) do
    pattern = Macro.to_string(ast)

    contains_predicates =
      selector.filters
      |> Enum.filter(&(&1.relation == :has_descendant and not &1.negated?))
      |> Enum.map(&%Predicate{op: :contains, binding: "f", value: Macro.to_string(&1.pattern)})

    %Query{
      source: :fragment,
      binding: "f",
      predicates: [%Predicate{op: :matches, binding: "f", value: pattern} | contains_predicates]
    }
  end

  def from_selector(%ExAST.Selector{}) do
    %Query{
      source: :fragment,
      binding: "f",
      predicates: [%Predicate{op: :matches, binding: "f", value: "_"}]
    }
  end

  @spec structural_only?(Query.t()) :: boolean()
  def structural_only?(%Query{source: :fragment, binding: binding, predicates: predicates}) do
    Enum.all?(predicates, fn predicate ->
      predicate = internal_predicate(predicate)
      match?({_, ^binding, _}, predicate) and structural_predicate?(predicate)
    end)
  end

  @spec compile(Query.t()) :: ExAST.Selector.t()
  def compile(%Query{source: :fragment, binding: binding, predicates: predicates}) do
    predicates =
      predicates
      |> Enum.map(&internal_predicate/1)
      |> Enum.filter(fn predicate ->
        match?({_, ^binding, _}, predicate) and structural_predicate?(predicate)
      end)

    {matches, filters} = Enum.split_with(predicates, &match?({:matches, _, _}, &1))

    selector =
      case matches do
        [{:matches, _binding, pattern} | _rest] -> ExAST.Query.from(pattern)
        [] -> ExAST.Query.from("_")
      end

    Enum.reduce(filters, selector, fn
      {:contains, _binding, pattern}, selector ->
        if ast_pattern?(pattern) do
          ExAST.Selector.where_predicate(selector, ExAST.Query.contains(pattern))
        else
          selector
        end
    end)
  end

  @spec required_terms(Query.t()) :: [String.t()]
  def required_terms(%Query{} = query) do
    selector = compile(query)
    plan = ExAST.Index.plan(selector)

    plan.required_terms
    |> MapSet.to_list()
    |> Enum.reject(&non_selective_root_term?/1)
  end

  @spec text_contains_patterns(Query.t()) :: [String.t()]
  def text_contains_patterns(%Query{binding: binding, predicates: predicates}) do
    Enum.flat_map(predicates, fn predicate ->
      case internal_predicate(predicate) do
        {:contains, ^binding, pattern} when is_binary(pattern) ->
          if ast_pattern?(pattern), do: [], else: [pattern]

        _predicate ->
          []
      end
    end)
  end

  defp non_selective_root_term?("def.visibility:public"), do: true
  defp non_selective_root_term?("def.visibility:private"), do: true
  defp non_selective_root_term?("node:def"), do: true
  defp non_selective_root_term?("node:def_like"), do: true
  defp non_selective_root_term?(_term), do: false

  defp structural_predicate?({:matches, _binding, _value}), do: true
  defp structural_predicate?({:contains, _binding, value}), do: ast_pattern?(value)

  defp structural_predicate?(_predicate), do: false

  @doc false
  def ast_pattern?(pattern) when is_binary(pattern) do
    if plain_text_token?(pattern) do
      false
    else
      case Exograph.ElixirParser.string_to_quoted(pattern) do
        {:ok, nil} -> false
        {:ok, {:__block__, _meta, []}} -> false
        {:ok, _ast} -> true
        {:error, _reason} -> false
      end
    end
  end

  def ast_pattern?(_pattern), do: false

  defp internal_predicate(%Predicate{} = predicate), do: Predicate.to_internal(predicate)
  defp internal_predicate(predicate) when is_tuple(predicate), do: predicate

  defp plain_text_token?(pattern) do
    String.match?(pattern, ~r/^[[:alnum:]_#!?@.-]+$/u) and
      not String.contains?(pattern, ["(", ")"])
  end
end
