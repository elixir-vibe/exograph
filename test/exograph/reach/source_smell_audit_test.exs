defmodule Exograph.Reach.SourceSmellAuditTest.LocalCheck do
  @moduledoc "Test-only Reach source-pattern smell check."

  use Reach.Smell.Check.Source

  smell(
    ~p[length(_)],
    :test_length_call,
    "length/1 call found"
  )
end

defmodule Exograph.Reach.SourceSmellAuditTest do
  use ExUnit.Case, async: false

  alias Exograph.Reach.SourceSmellAudit
  alias Exograph.Reach.SourceSmellAuditTest.LocalCheck

  setup do
    Exograph.DuckDBSupport.start_managed_repo!()
    prefix = "reach_source_smell_audit_#{System.unique_integer([:positive])}"

    on_exit(fn -> Exograph.DuckDBSupport.drop_prefix(prefix) end)

    {:ok, prefix: prefix}
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
