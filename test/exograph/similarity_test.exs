defmodule Exograph.SimilarityTest do
  use ExUnit.Case, async: false

  alias Exograph.DuckDBSupport

  test "uses indexed subhashes to find similar fragments" do
    DuckDBSupport.start_managed_repo!()
    prefix = "similarity_#{System.unique_integer([:positive])}"

    {:ok, index} =
      Exograph.index_sources(
        [
          {"lib/demo.ex",
           """
           defmodule Demo do
             def target(value) do
               Enum.map([value], fn item -> item + 1 end)
             end
           end
           """}
        ],
        DuckDBSupport.opts(prefix, extractors: [:ex_ast], min_mass: 1)
      )

    assert {:ok, [%{fragment: fragment, similarity: similarity} | _]} =
             Exograph.similar(
               index,
               """
               def target(value) do
                 Enum.map([value], fn item -> item + 1 end)
               end
               """,
               min_mass: 1,
               min_similarity: 0.5
             )

    assert fragment.name == "target"
    assert similarity >= 0.5

    assert {:ok, diagnostics} =
             Exograph.explain_similarity(
               index,
               """
               def target(value) do
                 Enum.map([value], fn item -> item + 1 end)
               end
               """,
               min_mass: 1,
               min_similarity: 0.5
             )

    assert diagnostics.query_subhashes > 0
    assert diagnostics.candidate_fragments > 0
    assert diagnostics.exact_scored_fragments == diagnostics.candidate_fragments
    assert is_boolean(diagnostics.fallback_to_full_scan)
    assert diagnostics.returned_results > 0
    assert is_number(diagnostics.elapsed_ms)
  end
end
