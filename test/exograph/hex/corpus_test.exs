defmodule Exograph.Hex.CorpusTest do
  use ExUnit.Case, async: false

  alias Exograph.DuckDBSupport
  alias Exograph.Storage.SQL
  alias Exograph.Web.SafeEval

  @moduletag :integration

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

  test "indexed package source preserves structural identifiers for search" do
    endpoint = "quack:127.0.0.1:#{Mix.Exograph.DuckDBOptions.free_tcp_port!()}"
    DuckDBSupport.start_managed_repo!(endpoint: endpoint)
    prefix = "exograph_duckdb_identifier_fidelity_#{System.unique_integer([:positive])}"

    source = """
    defmodule Fidelity.Probe do
      def handle_call(msg, _from, state) do
        users = Repo.all(User)
        ids = Enum.map(users, & &1.id)
        {:reply, Repo.get!(User, msg.id), Map.put(state, :ids, ids)}
      end
    end
    """

    opts =
      DuckDBSupport.opts(prefix,
        extractors: [:ex_ast],
        min_mass: 1,
        package_version: [
          ecosystem: :hex,
          name: "identifier_fidelity",
          version: "1.0.0",
          source_ref: "hex:identifier_fidelity:1.0.0"
        ]
      )

    assert {:ok, index} = Exograph.index_sources([{"lib/fidelity/probe.ex", source}], opts)

    assert_structural_hits(index, ~s|Repo.get!(_, _)|)
    assert_structural_hits(index, ~s|def handle_call(_, _, _) do ... end|)
    assert_structural_hits(index, ~s|Enum.map(_, _)|)

    fragments = indexed_fragments(prefix)
    assert Enum.any?(fragments, &(&1.name == "handle_call"))
    assert Enum.any?(fragments, &(&1.module == "Fidelity.Probe"))

    assert Enum.all?(fragments, fn fragment ->
             is_nil(fragment.name) or is_binary(fragment.name)
           end)
  end

  test "deferred fragment terms can be rebuilt from persisted fragment term arrays" do
    endpoint = "quack:127.0.0.1:#{Mix.Exograph.DuckDBOptions.free_tcp_port!()}"
    DuckDBSupport.start_managed_repo!(endpoint: endpoint)
    prefix = "exograph_duckdb_deferred_terms_#{System.unique_integer([:positive])}"

    source = """
    defmodule Deferred.Terms do
      def names(values), do: Enum.map(values, &String.trim/1)
    end
    """

    opts =
      DuckDBSupport.opts(prefix,
        extractors: [:ex_ast],
        min_mass: 1,
        defer_fragment_terms?: true,
        package_version: [
          ecosystem: :hex,
          name: "deferred_terms",
          version: "1.0.0",
          source_ref: "hex:deferred_terms:1.0.0"
        ]
      )

    assert {:ok, _index} = Exograph.index_sources([{"lib/deferred/terms.ex", source}], opts)
    assert table_count(prefix, "fragments") > 0
    assert table_count(prefix, "terms") > 0
    assert table_count(prefix, "fragment_terms") == 0

    assert :ok = Exograph.Storage.FragmentStore.rebuild_fragment_terms(opts)
    assert table_count(prefix, "fragment_terms") > 0
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

  defp package_version_fact_counts(prefix, suffix) do
    %{rows: rows} =
      Exograph.DuckDBRepo.query!(
        [
          "SELECT count(*) FROM ",
          SQL.table(prefix, suffix),
          " GROUP BY package_version_id ORDER BY package_version_id"
        ],
        []
      )

    Enum.map(rows, fn [count] -> count end)
  end

  defp table_count(prefix, suffix) do
    %{rows: [[count]]} =
      Exograph.DuckDBRepo.query!(["SELECT count(*) FROM ", SQL.table(prefix, suffix)], [])

    count
  end

  defp indexed_fragments(prefix) do
    prefix
    |> index!()
    |> then(&Exograph.Storage.FragmentStore.all(&1.fragment_store))
  end

  defp search_text(prefix, literal), do: Exograph.search_text(index!(prefix), literal)

  defp assert_structural_hits(index, pattern) do
    assert {:ok, query} =
             SafeEval.eval(~s|from(f in Fragment, where: contains(f, "#{pattern}"), limit: 20)|)

    assert {:ok, [_hit | _]} = Exograph.all(index, query, limit: 20)
  end

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
