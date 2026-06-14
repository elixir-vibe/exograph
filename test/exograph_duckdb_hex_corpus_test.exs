defmodule ExographDuckDBHexCorpusTest do
  use ExUnit.Case, async: false

  alias Exograph.DuckDBSupport

  @moduletag :integration

  test "duckdb offline build mode indexes Hex packages through the corpus pipeline" do
    endpoint = "quack:127.0.0.1:#{Mix.Exograph.BackendOptions.free_tcp_port!()}"
    DuckDBSupport.start_managed_repo!(endpoint: endpoint)
    prefix = "exograph_duckdb_hex_offline_#{System.unique_integer([:positive])}"
    opts = DuckDBSupport.opts(prefix, extractors: [:ex_ast], duckdb_build_mode: :offline)

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
