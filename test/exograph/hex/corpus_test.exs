defmodule Exograph.Hex.CorpusTest do
  use ExUnit.Case, async: false

  alias Exograph.DuckDBSupport

  @moduletag :integration

  test "duckdb offline build mode matches online counts for a top package" do
    endpoint = "quack:127.0.0.1:#{Mix.Exograph.DuckDBOptions.free_tcp_port!()}"
    DuckDBSupport.start_managed_repo!(endpoint: endpoint)

    online_prefix = "exograph_duckdb_hex_online_#{System.unique_integer([:positive])}"
    offline_prefix = "exograph_duckdb_hex_offline_#{System.unique_integer([:positive])}"

    online_results = index_top_package!(online_prefix, duckdb_build_mode: :online)
    offline_results = index_top_package!(offline_prefix, duckdb_build_mode: :offline)

    assert online_results.ok == offline_results.ok
    assert online_results.skipped == offline_results.skipped
    assert corpus_summary(offline_prefix) == corpus_summary(online_prefix)
  end

  test "duckdb offline build mode matches online Reach counts for a top package" do
    endpoint = "quack:127.0.0.1:#{Mix.Exograph.DuckDBOptions.free_tcp_port!()}"
    DuckDBSupport.start_managed_repo!(endpoint: endpoint)

    online_prefix = "exograph_duckdb_reach_online_#{System.unique_integer([:positive])}"
    offline_prefix = "exograph_duckdb_reach_offline_#{System.unique_integer([:positive])}"
    opts = [extractors: [:ex_ast, :reach]]

    online_results =
      index_top_package!(online_prefix, Keyword.put(opts, :duckdb_build_mode, :online))

    offline_results =
      index_top_package!(offline_prefix, Keyword.put(opts, :duckdb_build_mode, :offline))

    assert online_results.ok == offline_results.ok
    assert online_results.skipped == offline_results.skipped

    assert reach_summary(offline_prefix, reach_probe(online_prefix)) ==
             reach_summary(online_prefix)
  end

  test "duckdb fragment append mode is forwarded through the corpus pipeline" do
    endpoint = "quack:127.0.0.1:#{Mix.Exograph.DuckDBOptions.free_tcp_port!()}"
    DuckDBSupport.start_managed_repo!(endpoint: endpoint)
    prefix = "exograph_duckdb_append_mode_#{System.unique_integer([:positive])}"

    results =
      index_top_package!(prefix, duckdb_build_mode: :online, duckdb_fragment_append: :merge)

    assert results.ok == 1
    assert temporary_table_exists?(fragment_merge_table(prefix))
  end

  test "duckdb duplicate source paths are indexed once per package version" do
    endpoint = "quack:127.0.0.1:#{Mix.Exograph.DuckDBOptions.free_tcp_port!()}"
    DuckDBSupport.start_managed_repo!(endpoint: endpoint)
    single_prefix = "exograph_duckdb_single_source_#{System.unique_integer([:positive])}"
    duplicate_prefix = "exograph_duckdb_duplicate_source_#{System.unique_integer([:positive])}"

    source = """
    defmodule Duplicate.Source do
      def hello(name), do: {:ok, name}
    end
    """

    single_opts =
      DuckDBSupport.opts(single_prefix,
        extractors: [:ex_ast],
        min_mass: 1,
        package_version: duplicate_source_package_version()
      )

    duplicate_opts =
      DuckDBSupport.opts(duplicate_prefix,
        extractors: [:ex_ast],
        min_mass: 1,
        package_version: duplicate_source_package_version()
      )

    assert {:ok, _index} =
             Exograph.index_sources([{"lib/duplicate/source.ex", source}], single_opts)

    assert {:ok, _index} =
             Exograph.index_sources(
               [
                 {"lib/duplicate/source.ex", source},
                 {"lib/duplicate/source.ex", source}
               ],
               duplicate_opts
             )

    assert table_count(duplicate_prefix, "fragments") == table_count(single_prefix, "fragments")

    assert table_count(duplicate_prefix, "definitions") ==
             table_count(single_prefix, "definitions")

    assert table_count(duplicate_prefix, "references") == table_count(single_prefix, "references")
    assert table_count(duplicate_prefix, "comments") == table_count(single_prefix, "comments")
  end

  test "duckdb file lookup stays scoped to package version for duplicate file hashes" do
    endpoint = "quack:127.0.0.1:#{Mix.Exograph.DuckDBOptions.free_tcp_port!()}"
    DuckDBSupport.start_managed_repo!(endpoint: endpoint)
    prefix = "exograph_duckdb_file_scope_#{System.unique_integer([:positive])}"
    opts = DuckDBSupport.opts(prefix, extractors: [:ex_ast], min_mass: 1)

    source = """
    defmodule Shared.Source do
      def hello(name), do: {:ok, name}
    end
    """

    for version <- ["1.0.0", "2.0.0"] do
      assert {:ok, _index} =
               Exograph.index_sources(
                 [{"lib/shared/source.ex", source}],
                 Keyword.merge(opts,
                   migrate?: version == "1.0.0",
                   package_version: [
                     ecosystem: :hex,
                     name: "same_sha",
                     version: version,
                     source_ref: "hex:same_sha:#{version}"
                   ]
                 )
               )
    end

    assert [definition_count, definition_count] =
             package_version_fact_counts(prefix, "definitions")

    assert [reference_count, reference_count] =
             package_version_fact_counts(prefix, "references")

    assert definition_count > 0
    assert reference_count > 0
  end

  test "DuckDB indexes Hex packages through the corpus pipeline" do
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

  defp duplicate_source_package_version do
    [
      ecosystem: :hex,
      name: "duplicate_source",
      version: "1.0.0",
      source_ref: "hex:duplicate_source:1.0.0"
    ]
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

  defp reach_summary(prefix, probe \\ nil) do
    index = index!(prefix)
    probe = probe || reach_probe(prefix)

    summary = %{
      graph_nodes: table_count(prefix, "graph_nodes"),
      call_edges: table_count(prefix, "call_edges")
    }

    case probe do
      %{caller: caller, callee: callee} ->
        {:ok, caller_hits} = Exograph.search_callers(index, callee)
        {:ok, callee_hits} = Exograph.search_callees(index, caller)

        summary
        |> Map.put(:caller_hits, length(caller_hits))
        |> Map.put(:callee_hits, length(callee_hits))

      nil ->
        summary
    end
  end

  defp reach_probe(prefix) do
    %{rows: rows} =
      Exograph.DuckDBRepo.query!(
        ~s|SELECT caller_qualified_name, callee_qualified_name FROM "#{prefix}_call_edges" ORDER BY caller_qualified_name, callee_qualified_name LIMIT 1|,
        []
      )

    case rows do
      [[caller, callee] | _] -> %{caller: caller, callee: callee}
      [] -> nil
    end
  end

  defp fragment_merge_table(prefix) do
    source = "#{prefix}_fragments"
    hash = :erlang.phash2(source, 4_294_967_296) |> Integer.to_string(36)
    "exograph_fragment_merge_#{hash}"
  end

  defp temporary_table_exists?(table) do
    Exograph.DuckDBRepo.query!(~s|SELECT count(*) FROM "#{table}"|, [])
    true
  rescue
    _ -> false
  end

  defp package_version_fact_counts(prefix, suffix) do
    %{rows: rows} =
      Exograph.DuckDBRepo.query!(
        ~s|SELECT count(*) FROM "#{prefix}_#{suffix}" GROUP BY package_version_id ORDER BY package_version_id|,
        []
      )

    Enum.map(rows, fn [count] -> count end)
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
        repo: Exograph.DuckDBRepo,
        prefix: prefix,
        migrate?: false
      )

    index
  end
end
