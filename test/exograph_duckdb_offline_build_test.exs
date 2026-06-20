defmodule ExographDuckDBOfflineBuildTest do
  use ExUnit.Case, async: false

  alias Exograph.DuckDB.OfflineBuild
  alias Exograph.DuckDBSupport

  @moduletag :integration

  test "stages duplicate fragments and finalizes unique IDs" do
    endpoint = "quack:127.0.0.1:#{Mix.Exograph.DuckDBOptions.free_tcp_port!()}"
    DuckDBSupport.start_managed_repo!(endpoint: endpoint)
    prefix = "exograph_duckdb_offline_#{System.unique_integer([:positive])}"

    Exograph.DuckDB.migrate!(repo: Exograph.DuckDBRepo, prefix: prefix)

    now = DateTime.utc_now(:microsecond)

    OfflineBuild.create_stages!(Exograph.DuckDBRepo, prefix)

    {_count, _rows} =
      OfflineBuild.append_file_stage!(Exograph.DuckDBRepo, prefix, [
        file_row("lib/sample.ex", "sample-sha", now),
        file_row("lib/duplicate.ex", "sample-sha", now)
      ])

    file_ids = OfflineBuild.finalize_files!(Exograph.DuckDBRepo, prefix)
    file_id = Map.fetch!(file_ids, {nil, "sample-sha"})

    rows = [
      fragment_row(<<1>>, "first", file_id, 1, now),
      fragment_row(<<1>>, "duplicate", file_id, 2, now),
      fragment_row(<<2>>, "second", file_id, 3, now)
    ]

    {_count, _rows} = OfflineBuild.append_stage!(Exograph.DuckDBRepo, prefix, rows)

    {_count, _rows} =
      OfflineBuild.append_definition_stage!(Exograph.DuckDBRepo, prefix, [
        symbol_fact_row(<<1>>, "def", "first/0", file_id, 1, now),
        symbol_fact_row(<<2>>, "def", "second/0", file_id, 3, now)
      ])

    {_count, _rows} =
      OfflineBuild.append_reference_stage!(Exograph.DuckDBRepo, prefix, [
        symbol_fact_row(<<1>>, "local_call", "second/0", file_id, 2, now),
        symbol_fact_row(<<2>>, "local_call", "first/0", file_id, 4, now)
      ])

    {_count, _rows} =
      OfflineBuild.append_comment_stage!(Exograph.DuckDBRepo, prefix, [
        comment_row(<<1>>, "first comment", file_id, 1, now),
        comment_row(<<2>>, "second comment", file_id, 3, now)
      ])

    {_count, _rows} =
      OfflineBuild.append_term_stage!(Exograph.DuckDBRepo, prefix, [
        term_row("def"),
        term_row("def"),
        term_row("call")
      ])

    term_ids = OfflineBuild.finalize_terms!(Exograph.DuckDBRepo, prefix)

    {_count, _rows} =
      OfflineBuild.append_fragment_term_stage!(Exograph.DuckDBRepo, prefix, [
        fragment_term_row(<<1>>, Map.fetch!(term_ids, "def")),
        fragment_term_row(<<1>>, Map.fetch!(term_ids, "def")),
        fragment_term_row(<<1>>, Map.fetch!(term_ids, "call")),
        fragment_term_row(<<2>>, Map.fetch!(term_ids, "call"))
      ])

    {_count, _rows} =
      OfflineBuild.append_graph_node_stage!(Exograph.DuckDBRepo, prefix, [
        graph_node_row(101, <<1>>, "first/0", file_id, 1, now),
        graph_node_row(102, <<2>>, "second/0", file_id, 3, now)
      ])

    {_count, _rows} =
      OfflineBuild.append_call_edge_stage!(Exograph.DuckDBRepo, prefix, [
        call_edge_row(101, 102, <<1>>, "first/0", "second/0", file_id, 2, now)
      ])

    finalized = OfflineBuild.finalize!(Exograph.DuckDBRepo, prefix)
    ids = finalized.fragments

    assert map_size(ids) == 2
    assert Map.has_key?(ids, <<1>>)
    assert Map.has_key?(ids, <<2>>)
    assert fragment_count(prefix) == 2

    assert facts(prefix, "definitions", "qualified_name") == [
             {"first/0", Map.fetch!(ids, <<1>>)},
             {"second/0", Map.fetch!(ids, <<2>>)}
           ]

    assert facts(prefix, "references", "qualified_name") == [
             {"first/0", Map.fetch!(ids, <<2>>)},
             {"second/0", Map.fetch!(ids, <<1>>)}
           ]

    assert facts(prefix, "comments", "text") == [
             {"first comment", Map.fetch!(ids, <<1>>)},
             {"second comment", Map.fetch!(ids, <<2>>)}
           ]

    assert MapSet.new(fragment_terms(prefix)) ==
             MapSet.new([
               {Map.fetch!(term_ids, "call"), Map.fetch!(ids, <<1>>)},
               {Map.fetch!(term_ids, "call"), Map.fetch!(ids, <<2>>)},
               {Map.fetch!(term_ids, "def"), Map.fetch!(ids, <<1>>)}
             ])

    assert graph_node_count(prefix) == 2
    assert call_edges(prefix) == [{"first/0", "second/0", Map.fetch!(ids, <<1>>)}]

    ids_again = OfflineBuild.finalize_fragments!(Exograph.DuckDBRepo, prefix)

    assert ids_again == ids
    assert fragment_count(prefix) == 2

    DuckDBSupport.drop_prefix(prefix)
    Exograph.DuckDBRepo.query!(~s|DROP TABLE IF EXISTS "#{prefix}_file_stage"|, [])
    Exograph.DuckDBRepo.query!(~s|DROP TABLE IF EXISTS "#{prefix}_fragment_stage"|, [])
    Exograph.DuckDBRepo.query!(~s|DROP TABLE IF EXISTS "#{prefix}_definition_stage"|, [])
    Exograph.DuckDBRepo.query!(~s|DROP TABLE IF EXISTS "#{prefix}_reference_stage"|, [])
    Exograph.DuckDBRepo.query!(~s|DROP TABLE IF EXISTS "#{prefix}_comment_stage"|, [])
    Exograph.DuckDBRepo.query!(~s|DROP TABLE IF EXISTS "#{prefix}_term_stage"|, [])
    Exograph.DuckDBRepo.query!(~s|DROP TABLE IF EXISTS "#{prefix}_fragment_term_stage"|, [])
    Exograph.DuckDBRepo.query!(~s|DROP TABLE IF EXISTS "#{prefix}_graph_node_stage"|, [])
    Exograph.DuckDBRepo.query!(~s|DROP TABLE IF EXISTS "#{prefix}_call_edge_stage"|, [])
  end

  defp term_row(term), do: %{term: term}

  defp file_row(path, sha256, now) do
    %{
      package_id: nil,
      package_version_id: nil,
      path: path,
      source: "",
      comments_text: "",
      sha256: sha256,
      inserted_at: now,
      updated_at: now
    }
  end

  defp symbol_fact_row(fragment_content_hash, kind, qualified_name, file_id, line, now) do
    %{
      package_id: nil,
      package_version_id: nil,
      file_id: file_id,
      kind: kind,
      module: nil,
      name: qualified_name,
      arity: 0,
      qualified_name: qualified_name,
      line: line,
      column: 1,
      inserted_at: now,
      updated_at: now,
      fragment_content_hash: fragment_content_hash
    }
  end

  defp comment_row(fragment_content_hash, text, file_id, line, now) do
    %{
      package_id: nil,
      package_version_id: nil,
      file_id: file_id,
      text: text,
      line: line,
      column: 1,
      inserted_at: now,
      updated_at: now,
      fragment_content_hash: fragment_content_hash
    }
  end

  defp fragment_term_row(fragment_content_hash, term_id) do
    %{
      fragment_content_hash: fragment_content_hash,
      term_id: term_id
    }
  end

  defp graph_node_row(original_node_id, fragment_content_hash, qualified_name, file_id, line, now) do
    %{
      original_node_id: original_node_id,
      package_id: nil,
      package_version_id: nil,
      file_id: file_id,
      engine: "reach",
      external_id: "node:#{original_node_id}",
      kind: "function",
      module: nil,
      name: qualified_name,
      arity: 0,
      qualified_name: qualified_name,
      line: line,
      column: 1,
      metadata: "{}",
      inserted_at: now,
      updated_at: now,
      fragment_content_hash: fragment_content_hash
    }
  end

  defp call_edge_row(
         caller_id,
         callee_id,
         fragment_content_hash,
         caller,
         callee,
         file_id,
         line,
         now
       ) do
    %{
      package_id: nil,
      package_version_id: nil,
      file_id: file_id,
      caller_original_node_id: caller_id,
      callee_original_node_id: callee_id,
      call_site_fragment_content_hash: fragment_content_hash,
      caller_qualified_name: caller,
      callee_qualified_name: callee,
      line: line,
      column: 1,
      metadata: "{}",
      inserted_at: now,
      updated_at: now
    }
  end

  defp fragment_row(content_hash, name, file_id, line, now) do
    %{
      package_id: nil,
      package_version_id: nil,
      file_id: file_id,
      content_hash: content_hash,
      ast: :erlang.term_to_binary({:fragment, name}, [:compressed]),
      kind: "expression",
      module: nil,
      name: name,
      arity: nil,
      line: line,
      end_line: line,
      mass: 8,
      exact_hash: nil,
      terms: [],
      sub_hashes: [],
      inserted_at: now,
      updated_at: now
    }
  end

  defp facts(prefix, table, field) do
    %{rows: rows} =
      Exograph.DuckDBRepo.query!(
        ~s|SELECT "#{field}", fragment_id FROM "#{prefix}_#{table}" ORDER BY "#{field}"|,
        []
      )

    Enum.map(rows, fn [value, fragment_id] -> {value, fragment_id} end)
  end

  defp fragment_terms(prefix) do
    %{rows: rows} =
      Exograph.DuckDBRepo.query!(
        ~s|SELECT term_id, fragment_id FROM "#{prefix}_fragment_terms" ORDER BY term_id, fragment_id|,
        []
      )

    Enum.map(rows, fn [term_id, fragment_id] -> {term_id, fragment_id} end)
  end

  defp graph_node_count(prefix) do
    %{rows: [[count]]} =
      Exograph.DuckDBRepo.query!(~s|SELECT count(*) FROM "#{prefix}_graph_nodes"|, [])

    count
  end

  defp call_edges(prefix) do
    %{rows: rows} =
      Exograph.DuckDBRepo.query!(
        ~s|SELECT caller_qualified_name, callee_qualified_name, call_site_fragment_id FROM "#{prefix}_call_edges" ORDER BY caller_qualified_name, callee_qualified_name|,
        []
      )

    Enum.map(rows, fn [caller, callee, fragment_id] -> {caller, callee, fragment_id} end)
  end

  defp fragment_count(prefix) do
    %{rows: [[count]]} =
      Exograph.DuckDBRepo.query!(~s|SELECT count(*) FROM "#{prefix}_fragments"|, [])

    count
  end
end
