defmodule Exograph.PatternAuditTest.LocalCheck do
  @moduledoc "Test-only Reach source-pattern smell check."

  use Reach.Smell.Check.Source

  smell(
    ~p[length(_)],
    :test_length_call,
    "length/1 call found"
  )
end

defmodule Exograph.PatternAuditTest.PipeEquivalentCheck do
  @moduledoc "Test-only pipe-equivalent Reach source-pattern smell check."

  use Reach.Smell.Check.Source

  smell(
    ~p[Enum.dedup(_) |> MapSet.new()],
    :test_redundant_dedup,
    "Enum.dedup before MapSet.new"
  )
end

defmodule Exograph.PatternAuditTest.LiteralArgumentCheck do
  @moduledoc "Test-only Reach source-pattern smell check for literal arguments."

  use Reach.Smell.Check.Source

  smell(
    ~p[Enum.sort(_) |> Enum.at(-1)],
    :test_sort_at_negative_one,
    "Enum.sort before Enum.at(-1)"
  )

  smell(
    ~p[Enum.sort(_) |> Enum.take(-3)],
    :test_sort_take_negative_three,
    "Enum.sort before Enum.take(-3)"
  )

  smell(
    ~p[length(_) == 0],
    :test_length_zero,
    "length == 0"
  )

  smell(
    ~p[String.length(_) != 1],
    :test_string_length_not_one,
    "String.length != 1"
  )

  smell(
    ~p[if _, do: false, else: true],
    :test_if_false_true,
    "if false true"
  )
end

defmodule Exograph.PatternAuditTest do
  use ExUnit.Case, async: false

  alias Exograph.Integrations.Reach.PatternAudit, as: SourceSmellAudit

  alias Exograph.PatternAuditTest.{
    LiteralArgumentCheck,
    LocalCheck,
    PipeEquivalentCheck
  }

  setup do
    Exograph.DuckDBSupport.start_managed_repo!()
    prefix = "reach_source_smell_audit_#{System.unique_integer([:positive])}"

    on_exit(fn -> Exograph.DuckDBSupport.drop_prefix(prefix) end)

    {:ok, prefix: prefix}
  end

  test "exact audit finds pipe-equivalent source terms", %{prefix: prefix} do
    source = """
    defmodule Demo do
      def set(items) do
        items |> Enum.dedup() |> MapSet.new()
      end
    end
    """

    {:ok, index} =
      Exograph.index_sources(
        [{"lib/demo.ex", source}],
        Exograph.DuckDBSupport.opts(prefix, extractors: [:ex_ast], min_mass: 1)
      )

    assert {:ok, result} =
             SourceSmellAudit.scan(index, [PipeEquivalentCheck],
               candidate_mode: :exact,
               limit: 10,
               max_anchor_candidates: 10_000
             )

    assert [%{check: PipeEquivalentCheck, kind: :test_redundant_dedup, line: 3}] =
             result.findings

    assert result.skipped_patterns == []
  end

  test "exact audit ignores anchor candidate cap after required terms narrow candidates", %{
    prefix: prefix
  } do
    source = """
    defmodule Demo do
      def count_values(values) do
        length(values)
      end
    end
    """

    {:ok, index} =
      Exograph.index_sources(
        [{"lib/demo.ex", source}],
        Exograph.DuckDBSupport.opts(prefix, extractors: [:ex_ast], min_mass: 1)
      )

    assert {:ok, exact_result} =
             SourceSmellAudit.scan(index, [LocalCheck],
               candidate_mode: :exact,
               limit: 10,
               max_anchor_candidates: 0
             )

    assert [%{check: LocalCheck, kind: :test_length_call, line: 3}] = exact_result.findings
    assert exact_result.skipped_patterns == []

    assert {:ok, anchor_result} =
             SourceSmellAudit.scan(index, [LocalCheck],
               candidate_mode: :anchor,
               limit: 10,
               max_anchor_candidates: 0
             )

    assert anchor_result.findings == []
    assert [%{module: LocalCheck, kind: :test_length_call}] = anchor_result.skipped_patterns
  end

  test "exact audit deduplicates the same match from enclosing fragments", %{prefix: prefix} do
    source = """
    defmodule Demo do
      def set(items) do
        value = items |> Enum.dedup() |> MapSet.new()
        {:ok, value}
      end
    end
    """

    {:ok, index} =
      Exograph.index_sources(
        [{"lib/demo.ex", source}],
        Exograph.DuckDBSupport.opts(prefix, extractors: [:ex_ast], min_mass: 1)
      )

    assert {:ok, result} =
             SourceSmellAudit.scan(index, [PipeEquivalentCheck],
               candidate_mode: :exact,
               limit: 10,
               max_anchor_candidates: 10_000
             )

    assert [%{check: PipeEquivalentCheck, kind: :test_redundant_dedup, line: 3}] =
             result.findings

    assert result.skipped_patterns == []
  end

  test "exact audit finds literal argument source terms", %{prefix: prefix} do
    source = """
    defmodule Demo do
      def check(items, value) do
        items |> Enum.sort() |> Enum.at(-1)
        items |> Enum.sort() |> Enum.take(-3)
        length(items) == 0
        String.length(value) != 1
        if valid?(value), do: false, else: true
      end
    end
    """

    {:ok, index} =
      Exograph.index_sources(
        [{"lib/demo.ex", source}],
        Exograph.DuckDBSupport.opts(prefix, extractors: [:ex_ast], min_mass: 1)
      )

    assert {:ok, result} =
             SourceSmellAudit.scan(index, [LiteralArgumentCheck],
               candidate_mode: :exact,
               limit: 10,
               max_anchor_candidates: 10_000
             )

    assert result.skipped_patterns == []

    assert result.findings
           |> Enum.map(& &1.kind)
           |> Enum.sort() ==
             Enum.sort([
               :test_length_zero,
               :test_sort_at_negative_one,
               :test_sort_take_negative_three,
               :test_string_length_not_one,
               :test_if_false_true
             ])
  end

  test "loads a Reach source smell module and audits indexed fragments", %{prefix: prefix} do
    source = """
    defmodule Demo do
      def count_values(values) do
        values
        length(values)
      end
    end
    """

    {:ok, index} =
      Exograph.index_sources(
        [{"lib/demo.ex", source}],
        Exograph.DuckDBSupport.opts(prefix, extractors: [:ex_ast], min_mass: 1)
      )

    assert [pattern] = SourceSmellAudit.load_patterns!([LocalCheck])
    assert pattern.module == LocalCheck

    assert {:ok, result} =
             SourceSmellAudit.scan(index, [LocalCheck],
               limit: 10,
               max_anchor_candidates: 10_000
             )

    assert [%{check: LocalCheck, kind: :test_length_call, line: 4}] = result.findings

    assert {:ok, pattern_result} =
             SourceSmellAudit.scan_patterns(index, [pattern],
               limit: 10,
               max_anchor_candidates: 10_000
             )

    assert [%{check: LocalCheck, kind: :test_length_call, line: 4}] = pattern_result.findings
  end
end
