defmodule Exograph.Hex.CorpusTest do
  use ExUnit.Case, async: false

  import Ecto.Query

  alias Exograph.DuckDBSupport
  alias Exograph.Storage.Schema
  alias Exograph.Web.SafeEval

  @moduletag :integration

  test "shard workers do not overwrite run-level artifacts" do
    opts = [
      entries_output_path: "entries.ndjson",
      report_path: "report.json",
      timings_path: "timings.json",
      missing_tarballs_report_path: "missing.json",
      retry_count: 2
    ]

    shard_opts = Exograph.Hex.Corpus.shard_worker_opts(opts, 3)

    refute Keyword.has_key?(shard_opts, :entries_output_path)
    refute Keyword.has_key?(shard_opts, :report_path)
    refute Keyword.has_key?(shard_opts, :timings_path)
    refute Keyword.has_key?(shard_opts, :missing_tarballs_report_path)
    assert shard_opts[:retry_count] == 2
    assert shard_opts[:concurrency] == 3
    assert shard_opts[:progress_lifecycle?] == false
  end

  test "rejects ephemeral recovery modes for corpus indexes" do
    assert_raise ArgumentError, ~r/require durable DuckDB storage/, fn ->
      Exograph.Hex.Corpus.index(recovery_mode: :no_wal_writes)
    end
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

  test "reindexing a package version replaces code facts" do
    endpoint = "quack:127.0.0.1:#{Mix.Exograph.DuckDBOptions.free_tcp_port!()}"
    DuckDBSupport.start_managed_repo!(endpoint: endpoint)
    prefix = "exograph_duckdb_idempotent_facts_#{System.unique_integer([:positive])}"

    opts =
      DuckDBSupport.opts(prefix,
        extractors: [:ex_ast],
        min_mass: 1,
        package_version: duplicate_source_package_version()
      )

    source =
      "defmodule Idempotent.Facts do\n  # stable comment\n  def run, do: Enum.map([], & &1)\nend"

    assert {:ok, _index} = Exograph.index_sources([{"lib/idempotent.ex", source}], opts)

    counts =
      for table <- ["comments", "definitions", "references"], into: %{} do
        {table, table_count(prefix, table)}
      end

    assert {:ok, _index} =
             Exograph.index_sources(
               [{"lib/idempotent.ex", source}],
               Keyword.put(opts, :migrate?, false)
             )

    assert counts ==
             Map.new(counts, fn {table, _count} -> {table, table_count(prefix, table)} end)
  end

  test "identical sources at different paths remain distinct files" do
    endpoint = "quack:127.0.0.1:#{Mix.Exograph.DuckDBOptions.free_tcp_port!()}"
    DuckDBSupport.start_managed_repo!(endpoint: endpoint)
    prefix = "exograph_duckdb_duplicate_content_#{System.unique_integer([:positive])}"

    source = "defmodule Shared.Source do\n  def hello, do: :ok\nend\n"

    assert {:ok, _index} =
             Exograph.index_sources(
               [
                 {"lib/first.ex", source},
                 {"lib/second.ex", source}
               ],
               DuckDBSupport.opts(prefix,
                 extractors: [:ex_ast],
                 min_mass: 1,
                 package_version: duplicate_source_package_version()
               )
             )

    assert table_count(prefix, "files") == 2

    unresolved_fragments =
      from(fragment in Schema.source(:fragments, prefix), where: is_nil(fragment.file_id))
      |> Exograph.DuckDBRepo.aggregate(:count)

    assert unresolved_fragments == 0
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

  test "fragment terms are materialized without persisted fragment term arrays" do
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
    assert table_count(prefix, "fragment_terms") > 0

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
    from(fact in table_source(prefix, suffix),
      group_by: fact.package_version_id,
      order_by: fact.package_version_id,
      select: count(fact.id)
    )
    |> Exograph.DuckDBRepo.all()
  end

  defp table_count(prefix, suffix) do
    Exograph.DuckDBRepo.aggregate(table_source(prefix, suffix), :count)
  end

  defp table_source(prefix, "comments"), do: Schema.source(:comments, prefix)
  defp table_source(prefix, "definitions"), do: Schema.source(:definitions, prefix)
  defp table_source(prefix, "files"), do: Schema.source(:files, prefix)
  defp table_source(prefix, "fragments"), do: Schema.source(:fragments, prefix)
  defp table_source(prefix, "references"), do: Schema.source(:references, prefix)
  defp table_source(prefix, "terms"), do: Schema.source(:terms, prefix)
  defp table_source(prefix, "fragment_terms"), do: Schema.source(:fragment_terms, prefix)

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
