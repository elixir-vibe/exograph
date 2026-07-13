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
               min_similarity: 0.8
             )

    assert fragment.name == "target"
    assert similarity >= 0.8

    assert {:ok, diagnostics} =
             Exograph.explain_similarity(
               index,
               """
               def target(value) do
                 Enum.map([value], fn item -> item + 1 end)
               end
               """,
               min_mass: 1,
               min_similarity: 0.8
             )

    assert diagnostics.query_subhashes > 0
    assert diagnostics.candidate_fragments > 0
    assert diagnostics.exact_scored_fragments == diagnostics.candidate_fragments
    refute diagnostics.fallback_to_full_scan
    assert diagnostics.returned_results > 0
    assert is_number(diagnostics.elapsed_ms)

    query = """
    def target(value) do
      Enum.map([value], fn item -> item + 1 end)
    end
    """

    assert {:ok, prefiltered} =
             Exograph.similar(index, query, min_mass: 1, min_similarity: 0.8)

    assert {:ok, full_scan} =
             Exograph.similar(
               index,
               query,
               min_mass: 1,
               min_similarity: 0.8,
               force_full_scan: true
             )

    assert similarity_signature(prefiltered) == similarity_signature(full_scan)
  end

  test "preserves recall for normalized similarity variants" do
    DuckDBSupport.start_managed_repo!()
    prefix = "similarity_variants_#{System.unique_integer([:positive])}"

    {:ok, index} =
      Exograph.index_sources(
        [
          {"lib/variants.ex",
           """
           defmodule Variants do
             def increment(value) do
               Enum.map([value], fn item -> item + 1 end)
             end

             def increment_with_offset(value) do
               Enum.map([value], fn item -> item + 2 end)
             end

             def mapped_value(value) do
               mapped = Enum.map([value], fn item -> item + 1 end)
               mapped
             end

             def reordered(value) do
               label = :value
               Enum.map([value], fn item -> {label, item + 1} end)
             end
           end
           """}
        ],
        DuckDBSupport.opts(prefix, extractors: [:ex_ast], min_mass: 1)
      )

    [
      "def increment(number), do: Enum.map([number], fn entry -> entry + 1 end)",
      "def increment(value), do: Enum.map([value], fn item -> item + 2 end)",
      "def mapped_value(value) do\n  result = Enum.map([value], fn item -> item + 1 end)\n  result\nend",
      "def unrelated(value), do: {:unindexed, value}"
    ]
    |> Enum.each(fn query ->
      opts = [min_mass: 1, min_similarity: 0.3, limit: 20]

      assert {:ok, prefiltered} = Exograph.similar(index, query, opts)

      assert {:ok, full_scan} =
               Exograph.similar(index, query, Keyword.put(opts, :force_full_scan, true))

      assert similarity_signature(prefiltered) == similarity_signature(full_scan)
    end)
  end

  defp similarity_signature(results) do
    Enum.map(results, &{&1.fragment.id, &1.similarity})
  end
end
