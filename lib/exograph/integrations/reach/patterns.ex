defmodule Exograph.Integrations.Reach.Patterns do
  @moduledoc "Translates Reach source-pattern checks into Exograph audit patterns."

  alias Exograph.PatternAudit.Pattern

  @spec load!([module()]) :: [Pattern.t()]
  def load!(modules) when is_list(modules) do
    modules
    |> Enum.flat_map(&load_module!/1)
    |> Enum.with_index()
    |> Enum.map(fn {pattern, id} -> %{pattern | id: id} end)
  end

  defp load_module!(module) when is_atom(module) do
    ensure_source_pattern_check!(module)
    config = Reach.Smell.PatternConfig.normalize(module, module.__reach_pattern_check__())

    pattern_entries(module, :pattern, config.patterns) ++
      pattern_entries(module, :query, config.queries)
  end

  defp ensure_source_pattern_check!(module) do
    cond do
      not Code.ensure_loaded?(module) ->
        raise ArgumentError, "could not load Reach smell module #{inspect(module)}"

      not function_exported?(module, :__reach_pattern_check__, 0) ->
        raise ArgumentError,
              "#{inspect(module)} is not a Reach source-pattern smell check " <>
                "or does not expose __reach_pattern_check__/0"

      true ->
        :ok
    end
  end

  defp pattern_entries(module, source, entries) do
    Enum.map(entries, fn {pattern_or_fun, kind, message, prefilter} ->
      pattern = if source == :query, do: apply(module, pattern_or_fun, []), else: pattern_or_fun
      plan = ExAST.Index.plan(pattern)
      candidate_terms = MapSet.union(plan.required_terms, plan.optional_terms)

      %Pattern{
        module: module,
        source: source,
        kind: kind,
        message: message,
        prefilter: prefilter,
        pattern: compile_pattern(pattern),
        required_terms: candidate_terms
      }
    end)
  end

  defp compile_pattern(%ExAST.Selector{} = pattern), do: pattern

  defp compile_pattern(pattern) do
    if ExAST.Pattern.multi_node?(pattern),
      do: pattern,
      else: ExAST.Pattern.compile(pattern)
  end
end
