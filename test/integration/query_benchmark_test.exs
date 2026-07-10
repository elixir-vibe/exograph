defmodule Exograph.Integration.QueryBenchmarkTest do
  use ExUnit.Case, async: false

  alias Exograph.DSL.Query
  alias Exograph.QueryBenchmarkFixture

  @moduletag :benchmark

  setup do
    %{index: QueryBenchmarkFixture.build_index!()}
  end

  test "records deterministic structural, relational, and text-search baselines", %{index: index} do
    selective = Exograph.explain(index, "Repo.get!(_, _)", limit: 5)
    broad = Exograph.explain(index, "def _ do ... end", limit: 5)

    joined =
      QueryBenchmarkFixture.measure(fn ->
        Exograph.all(
          index,
          %Query{
            source: :fragment,
            binding: :f,
            joins: [{:assoc, :f, :r, :references}],
            predicates: [{:eq, :r, :qualified_name, "Enum.map/2"}]
          },
          limit: 5
        )
      end)

    first_page =
      QueryBenchmarkFixture.measure(fn ->
        Exograph.all(
          index,
          %Query{
            source: :fragment,
            binding: :f,
            predicates: [{:matches, :f, "def _ do ... end"}]
          },
          limit: 5
        )
      end)

    {:ok, [first | _]} = first_page.result
    cursor = {first.fragment.file, first.fragment.line, first.fragment.id}

    next_page =
      QueryBenchmarkFixture.measure(fn ->
        Exograph.all(
          index,
          %Query{
            source: :fragment,
            binding: :f,
            predicates: [{:matches, :f, "def _ do ... end"}]
          },
          limit: 5,
          cursor: cursor
        )
      end)

    text =
      QueryBenchmarkFixture.measure(fn ->
        Exograph.search_text(index, "benchmark marker", limit: 5)
      end)

    regex =
      QueryBenchmarkFixture.measure(fn ->
        Exograph.search_text(index, ~r/benchmark marker/, limit: 5)
      end)

    report = %{
      selective: explain_metrics(selective),
      broad: explain_metrics(broad),
      joined_ms: joined.elapsed_ms,
      page_one_ms: first_page.elapsed_ms,
      page_two_ms: next_page.elapsed_ms,
      text_ms: text.elapsed_ms,
      regex_ms: regex.elapsed_ms
    }

    IO.puts("query benchmark: #{Jason.encode!(report)}")

    assert selective.metrics.candidate_rows > 0
    assert selective.metrics.matches > 0
    assert broad.metrics.candidate_rows >= selective.metrics.candidate_rows
    assert {:ok, [_ | _]} = joined.result
    assert {:ok, [_ | _]} = next_page.result
    assert {:ok, [_ | _]} = text.result
    assert {:ok, [_ | _]} = regex.result
  end

  defp explain_metrics(explanation) do
    explanation.metrics
    |> Map.take([
      :candidate_rows,
      :hydrated_fragments,
      :verified_fragments,
      :rejected_fragments,
      :matches,
      :total_ms
    ])
  end
end
