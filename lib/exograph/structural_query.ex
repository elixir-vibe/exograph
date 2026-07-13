defmodule Exograph.StructuralQuery do
  @moduledoc false

  defstruct source: nil,
            required_terms: MapSet.new(),
            optional_terms: MapSet.new(),
            negative_terms: MapSet.new(),
            candidate_groups: [],
            verifier: nil

  @type verifier :: {:pattern, ExAST.Pattern.pattern()} | {:selector, ExAST.Selector.t()} | nil

  @type t :: %__MODULE__{
          source: term(),
          required_terms: MapSet.t(String.t()),
          optional_terms: MapSet.t(String.t()),
          negative_terms: MapSet.t(String.t()),
          candidate_groups: [MapSet.t(String.t())],
          verifier: verifier()
        }

  @spec pattern(ExAST.Pattern.pattern()) :: t()
  def pattern(pattern) do
    compiled_pattern = compile_pattern(pattern)
    plan = ExAST.Index.plan(compiled_pattern)

    %__MODULE__{
      source: pattern,
      required_terms: plan.required_terms,
      optional_terms: plan.optional_terms,
      negative_terms: plan.negative_terms,
      candidate_groups: plan.candidate_groups,
      verifier: {:pattern, compiled_pattern}
    }
  end

  defp compile_pattern(pattern) when is_binary(pattern),
    do: Exograph.PatternParser.parse!(pattern)

  defp compile_pattern(pattern), do: pattern

  @spec selector(ExAST.Selector.t()) :: t()
  def selector(%ExAST.Selector{} = selector) do
    plan = ExAST.Index.plan(selector)

    %__MODULE__{
      source: selector,
      required_terms: plan.required_terms,
      optional_terms: plan.optional_terms,
      negative_terms: plan.negative_terms,
      candidate_groups: plan.candidate_groups,
      verifier: {:selector, selector}
    }
  end

  @spec requires_source?(t()) :: boolean()
  def requires_source?(%__MODULE__{source: %ExAST.Selector{} = selector}),
    do: ExAST.Selector.requires_source?(selector)

  def requires_source?(_query), do: false

  @spec comment_texts(t()) :: [String.t()]
  def comment_texts(%__MODULE__{source: %ExAST.Selector{filters: filters}}) do
    filters
    |> Enum.flat_map(&comment_texts_from_predicate/1)
    |> Enum.uniq()
  end

  def comment_texts(_query), do: []

  @spec verify(t(), Macro.t() | Exograph.Fragment.t()) :: {:ok, [map()]} | :error
  def verify(%__MODULE__{verifier: {:pattern, pattern}}, %{ast: ast}) do
    verify(%__MODULE__{verifier: {:pattern, pattern}}, ast)
  end

  def verify(%__MODULE__{verifier: {:pattern, pattern}}, ast) do
    case ExAST.Pattern.match(ast, pattern) do
      {:ok, captures} -> {:ok, [%{node: ast, captures: captures}]}
      :error -> :error
    end
  end

  def verify(%__MODULE__{verifier: {:selector, selector}}, %{source: source, ast: ast}) do
    cond do
      simple_self_capture_selector?(selector) ->
        verify_simple_self_capture(selector, ast)

      ExAST.Selector.requires_source?(selector) ->
        verify_selector(source || ast, selector)

      true ->
        verify_selector(ast, selector)
    end
  end

  def verify(%__MODULE__{verifier: {:selector, selector}}, ast) do
    if simple_self_capture_selector?(selector) do
      verify_simple_self_capture(selector, ast)
    else
      verify_selector(ast, selector)
    end
  end

  def verify(%__MODULE__{verifier: nil}, _ast), do: {:ok, []}

  defp verify_selector(input, selector) do
    case ExAST.Selector.find_all(input, selector) do
      [] -> :error
      matches -> {:ok, matches}
    end
  end

  defp verify_simple_self_capture(
         %ExAST.Selector{steps: [self: pattern], filters: filters},
         ast
       ) do
    {_ast, matches} =
      Macro.prewalk(ast, [], fn node, matches ->
        case ExAST.Pattern.match(node, pattern) do
          {:ok, captures} ->
            if Enum.all?(filters, &capture_predicate?(&1, captures)) do
              {node, [%{node: node, range: nil, source: nil, captures: captures} | matches]}
            else
              {node, matches}
            end

          :error ->
            {node, matches}
        end
      end)

    case Enum.reverse(matches) do
      [] -> :error
      matches -> {:ok, matches}
    end
  end

  defp simple_self_capture_selector?(%ExAST.Selector{steps: [self: _pattern], filters: filters}) do
    Enum.all?(filters, fn
      %ExAST.Selector.Predicate{relation: :captures, pattern: fun} -> is_function(fun, 1)
      _predicate -> false
    end)
  end

  defp simple_self_capture_selector?(_selector), do: false

  defp capture_predicate?(%ExAST.Selector.Predicate{relation: :captures, pattern: fun}, captures) do
    fun.(captures)
  end

  defp comment_texts_from_predicate(%ExAST.Selector.Predicate{pattern: predicates})
       when is_list(predicates),
       do: Enum.flat_map(predicates, &comment_texts_from_predicate/1)

  defp comment_texts_from_predicate(%ExAST.Selector.Predicate{
         relation: relation,
         pattern: %ExAST.Selector.CommentMatcher{kind: :text, value: value}
       })
       when relation in [
              :comment,
              :comment_before,
              :comment_after,
              :comment_inside,
              :comment_inline
            ],
       do: [value]

  defp comment_texts_from_predicate(_predicate), do: []
end
