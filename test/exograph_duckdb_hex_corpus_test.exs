defmodule ExographDuckDBHexCorpusTest do
  use ExUnit.Case, async: false

  alias Exograph.DuckDBSupport

  @moduletag :integration

  test "duckdb offline build mode matches online counts for a top package" do
    endpoint = "quack:127.0.0.1:#{Mix.Exograph.BackendOptions.free_tcp_port!()}"
    DuckDBSupport.start_managed_repo!(endpoint: endpoint)

    online_prefix = "exograph_duckdb_hex_online_#{System.unique_integer([:positive])}"
    offline_prefix = "exograph_duckdb_hex_offline_#{System.unique_integer([:positive])}"

    online_results = index_top_package!(online_prefix, duckdb_build_mode: :online)
    offline_results = index_top_package!(offline_prefix, duckdb_build_mode: :offline)

    assert online_results.ok == offline_results.ok
    assert online_results.skipped == offline_results.skipped
    assert corpus_summary(offline_prefix) == corpus_summary(online_prefix)
  end

  test "duckdb backend indexes Hex packages through the corpus pipeline" do
    if System.get_env("QUACKDB_TEST_URI") do
      DuckDBSupport.start_repo!()
      prefix = "exograph_duckdb_hex_#{System.unique_integer([:positive])}"
      opts = DuckDBSupport.opts(prefix, extractors: [:ex_ast])

      results =
        Exograph.Hex.Corpus.index(
          Keyword.merge(opts,
            mode: :top,
            limit: 1,
            concurrency: 1,
            min_mass: 4,
            resume: false,
            bm25?: true,
            timeout: 120_000
          )
        )

      assert results.ok >= 1
      assert [_fragment | _] = indexed_fragments(prefix)
      assert {:ok, [_hit | _]} = search_text(prefix, "defmodule")
    end
  end

  defp index_top_package!(prefix, opts) do
    prefix
    |> DuckDBSupport.opts(Keyword.merge([extractors: [:ex_ast]], opts))
    |> Keyword.merge(
      mode: :top,
      limit: 1,
      concurrency: 1,
      min_mass: 4,
      resume: false,
      bm25?: true,
      timeout: 120_000
    )
    |> Exograph.Hex.Corpus.index()
  end

  defp corpus_summary(prefix) do
    index = index!(prefix)
    {:ok, text_hits} = Exograph.search_text(index, "defmodule")
    {:ok, definition_hits} = Exograph.search_definitions(index, "Jason")
    {:ok, reference_hits} = Exograph.search_references(index, "Jason")

    %{
      files: table_count(prefix, "files"),
      fragments: table_count(prefix, "fragments"),
      terms: table_count(prefix, "terms"),
      fragment_terms: table_count(prefix, "fragment_terms"),
      definitions: table_count(prefix, "definitions"),
      references: table_count(prefix, "references"),
      comments: table_count(prefix, "comments"),
      defmodule_text_hits: length(text_hits),
      jason_definition_hits: length(definition_hits),
      jason_reference_hits: length(reference_hits)
    }
  end

  defp table_count(prefix, suffix) do
    %{rows: [[count]]} =
      Exograph.DuckDBRepo.query!(~s|SELECT count(*) FROM "#{prefix}_#{suffix}"|, [])

    count
  end

  defp indexed_fragments(prefix) do
    prefix
    |> index!()
    |> then(&Exograph.Storage.Ecto.FragmentStore.all(&1.fragment_store))
  end

  defp search_text(prefix, literal), do: Exograph.search_text(index!(prefix), literal)

  defp index!(prefix) do
    {:ok, index} =
      Exograph.index([],
        backend: :duckdb,
        repo: Exograph.DuckDBRepo,
        prefix: prefix,
        migrate?: false
      )

    index
  end
end
