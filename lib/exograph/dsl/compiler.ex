defmodule Exograph.DSL.Compiler do
  @moduledoc false

  alias Exograph.DSL.Query

  @spec from_pattern(ExAST.Pattern.pattern() | ExAST.Selector.t()) :: Query.t()
  def from_pattern(pattern) when is_binary(pattern) do
    %Query{
      source: :fragment,
      binding: :f,
      predicates: [{:matches, :f, pattern}]
    }
  end

  @spec from_selector(ExAST.Selector.t()) :: Query.t()
  def from_selector(%ExAST.Selector{steps: [{:self, ast}]} = selector) do
    pattern = Macro.to_string(ast)

    contains_predicates =
      selector.filters
      |> Enum.filter(&(&1.relation == :has_descendant and not &1.negated?))
      |> Enum.map(&{:contains, :f, Macro.to_string(&1.pattern)})

    %Query{
      source: :fragment,
      binding: :f,
      predicates: [{:matches, :f, pattern} | contains_predicates]
    }
  end

  def from_selector(%ExAST.Selector{}) do
    %Query{
      source: :fragment,
      binding: :f,
      predicates: [{:matches, :f, "_"}]
    }
  end

  @spec structural_only?(Query.t()) :: boolean()
  def structural_only?(%Query{source: :fragment, binding: binding, predicates: predicates}) do
    Enum.all?(predicates, fn predicate ->
      match?({_, ^binding, _}, normalize_predicate(predicate)) and
        structural_predicate?(predicate)
    end)
  end

  @spec compile(Query.t()) :: ExAST.Selector.t()
  def compile(%Query{source: :fragment, binding: binding, predicates: predicates}) do
    predicates =
      Enum.filter(predicates, fn predicate ->
        match?({_, ^binding, _}, normalize_predicate(predicate)) and
          structural_predicate?(predicate)
      end)

    {matches, filters} = Enum.split_with(predicates, &match?({:matches, _binding, _pattern}, &1))

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
    MapSet.to_list(plan.required_terms)
  end

  defp structural_predicate?({:matches, _binding, _value}), do: true
  defp structural_predicate?({:contains, _binding, value}), do: ast_pattern?(value)

  defp structural_predicate?(_predicate), do: false

  defp ast_pattern?(pattern) when is_binary(pattern) do
    case Code.string_to_quoted(pattern) do
      {:ok, nil} -> false
      {:ok, {:__block__, _meta, []}} -> false
      {:ok, _ast} -> true
      {:error, _reason} -> false
    end
  end

  defp ast_pattern?(_pattern), do: false

  defp normalize_predicate({kind, binding, value}), do: {kind, binding, value}
  defp normalize_predicate({kind, binding, _field, value}), do: {kind, binding, value}
  defp normalize_predicate({kind, binding, _field, _op, value}), do: {kind, binding, value}
end
