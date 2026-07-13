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

    similarity =
      QueryBenchmarkFixture.measure(fn ->
        Exograph.explain_similarity(
          index,
          "def run(value), do: helper(value)",
          min_mass: 1,
          min_similarity: 0.0
        )
      end)

    similarity_fallback =
      QueryBenchmarkFixture.measure(fn ->
        Exograph.explain_similarity(
          index,
          "def unrelated(value), do: :unindexed",
          min_mass: 1,
          min_similarity: 0.0
        )
      end)

    one_join = measure_join(index, one_join_query())
    two_join = measure_join(index, two_join_query())
    three_join = measure_join(index, three_join_query())

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

    identifier_explanation = Exograph.explain_text(index, "Enum.map")

    identifier_fts =
      QueryBenchmarkFixture.measure(fn ->
        Exograph.search_text(index, "Enum.map", limit: 5)
      end)

    identifier_ilike =
      QueryBenchmarkFixture.measure(fn ->
        Exograph.search_text(index, "Enum.map", limit: 5, force_ilike: true)
      end)

    regex =
      QueryBenchmarkFixture.measure(fn ->
        Exograph.search_text(index, ~r/benchmark marker/, limit: 5)
      end)

    report = %{
      selective: explain_metrics(selective),
      broad: explain_metrics(broad),
      similarity: similarity.result |> elem(1),
      similarity_fallback: similarity_fallback.result |> elem(1),
      one_join: join_metrics(one_join),
      two_join: join_metrics(two_join),
      three_join: join_metrics(three_join),
      page_one_ms: first_page.elapsed_ms,
      page_two_ms: next_page.elapsed_ms,
      text_ms: text.elapsed_ms,
      identifier:
        Map.take(identifier_explanation, [:strategy, :identifier_tokens, :candidate_file_count]),
      identifier_fts_ms: identifier_fts.elapsed_ms,
      identifier_ilike_ms: identifier_ilike.elapsed_ms,
      regex_ms: regex.elapsed_ms
    }

    IO.puts("query benchmark: #{Jason.encode!(report)}")

    assert selective.metrics.candidate_rows > 0
    assert selective.metrics.matches > 0
    assert broad.metrics.candidate_rows >= selective.metrics.candidate_rows
    assert {:ok, similarity_diagnostics} = similarity.result
    assert similarity_diagnostics.exact_scored_fragments > 0
    assert {:ok, fallback_diagnostics} = similarity_fallback.result
    assert fallback_diagnostics.fallback_to_full_scan
    assert {:ok, [_ | _]} = one_join.result
    assert one_join.query_count == 3
    assert {:ok, [_ | _]} = two_join.result
    assert two_join.query_count == 5
    assert {:ok, [_ | _]} = three_join.result
    assert three_join.query_count == 6
    assert {:ok, [_ | _]} = next_page.result
    assert {:ok, [_ | _]} = text.result
    assert identifier_explanation.strategy in [:bm25, :ilike]
    assert identifier_explanation.identifier_tokens == ["enum", "map"]
    assert identifier_explanation.candidate_file_count > 0
    assert {:ok, identifier_fts_hits} = identifier_fts.result
    assert {:ok, identifier_ilike_hits} = identifier_ilike.result

    assert Enum.map(identifier_fts_hits, & &1.fragment.id) ==
             Enum.map(identifier_ilike_hits, & &1.fragment.id)

    assert {:ok, [_ | _]} = regex.result
  end

  defp measure_join(index, query) do
    {:ok, counter} = Agent.start_link(fn -> 0 end)
    handler_id = "query-benchmark-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler_id,
        Exograph.DuckDBRepo.config()[:telemetry_prefix] ++ [:query],
        &__MODULE__.count_query/4,
        counter
      )

    measurement = QueryBenchmarkFixture.measure(fn -> Exograph.all(index, query, limit: 5) end)
    :ok = :telemetry.detach(handler_id)
    query_count = Agent.get(counter, & &1)
    :ok = Agent.stop(counter)

    Map.put(measurement, :query_count, query_count)
  end

  def count_query(_event, _measurements, _metadata, agent), do: Agent.update(agent, &(&1 + 1))

  defp one_join_query do
    %Query{
      source: :fragment,
      binding: :f,
      joins: [{:assoc, :f, :r, :references}],
      predicates: [{:eq, :r, :qualified_name, "Enum.map/2"}]
    }
  end

  defp two_join_query do
    %Query{
      source: :fragment,
      binding: :f,
      joins: [{:assoc, :f, :d, :definitions}, {:assoc, :f, :r, :references}],
      predicates: [
        {:eq, :d, :qualified_name, "Benchmark.Fixture1.run/1"},
        {:eq, :r, :qualified_name, "Enum.map/2"}
      ]
    }
  end

  defp three_join_query do
    %Query{
      source: :fragment,
      binding: :f,
      joins: [
        {:assoc, :f, :d, :definitions},
        {:assoc, :f, :r, :references},
        {:assoc, :f, :e, :calls}
      ],
      predicates: [
        {:eq, :d, :qualified_name, "Benchmark.Fixture1.run/1"},
        {:eq, :r, :qualified_name, "Enum.map/2"}
      ]
    }
  end

  defp join_metrics(measurement) do
    %{
      elapsed_ms: measurement.elapsed_ms,
      query_count: measurement.query_count,
      returned_rows: measurement.result |> elem(1) |> length()
    }
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
