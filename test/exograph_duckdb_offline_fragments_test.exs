defmodule ExographDuckDBOfflineFragmentsTest do
  use ExUnit.Case, async: false

  alias Exograph.DuckDB.OfflineFragments
  alias Exograph.DuckDBSupport

  @moduletag :integration

  test "stages duplicate fragments and finalizes unique IDs" do
    endpoint = "quack:127.0.0.1:#{Mix.Exograph.BackendOptions.free_tcp_port!()}"
    DuckDBSupport.start_managed_repo!(endpoint: endpoint)
    prefix = "exograph_duckdb_offline_#{System.unique_integer([:positive])}"

    Exograph.DuckDB.migrate!(repo: Exograph.DuckDBRepo, prefix: prefix)

    now = DateTime.utc_now(:microsecond)
    file_id = insert_file!(prefix, now)

    rows = [
      fragment_row(<<1>>, "first", file_id, 1, now),
      fragment_row(<<1>>, "duplicate", file_id, 2, now),
      fragment_row(<<2>>, "second", file_id, 3, now)
    ]

    OfflineFragments.create_stage!(Exograph.DuckDBRepo, prefix)
    OfflineFragments.create_definition_stage!(Exograph.DuckDBRepo, prefix)
    OfflineFragments.create_reference_stage!(Exograph.DuckDBRepo, prefix)
    OfflineFragments.create_comment_stage!(Exograph.DuckDBRepo, prefix)
    OfflineFragments.create_term_stage!(Exograph.DuckDBRepo, prefix)
    OfflineFragments.create_fragment_term_stage!(Exograph.DuckDBRepo, prefix)

    {_count, _rows} = OfflineFragments.append_stage!(Exograph.DuckDBRepo, prefix, rows)

    {_count, _rows} =
      OfflineFragments.append_definition_stage!(Exograph.DuckDBRepo, prefix, [
        symbol_fact_row(<<1>>, "def", "first/0", file_id, 1, now),
        symbol_fact_row(<<2>>, "def", "second/0", file_id, 3, now)
      ])

    {_count, _rows} =
      OfflineFragments.append_reference_stage!(Exograph.DuckDBRepo, prefix, [
        symbol_fact_row(<<1>>, "local_call", "second/0", file_id, 2, now),
        symbol_fact_row(<<2>>, "local_call", "first/0", file_id, 4, now)
      ])

    {_count, _rows} =
      OfflineFragments.append_comment_stage!(Exograph.DuckDBRepo, prefix, [
        comment_row(<<1>>, "first comment", file_id, 1, now),
        comment_row(<<2>>, "second comment", file_id, 3, now)
      ])

    {_count, _rows} =
      OfflineFragments.append_term_stage!(Exograph.DuckDBRepo, prefix, [
        term_row("def"),
        term_row("def"),
        term_row("call")
      ])

    term_ids = OfflineFragments.finalize_terms!(Exograph.DuckDBRepo, prefix)

    {_count, _rows} =
      OfflineFragments.append_fragment_term_stage!(Exograph.DuckDBRepo, prefix, [
        fragment_term_row(<<1>>, Map.fetch!(term_ids, "def")),
        fragment_term_row(<<1>>, Map.fetch!(term_ids, "def")),
        fragment_term_row(<<1>>, Map.fetch!(term_ids, "call")),
        fragment_term_row(<<2>>, Map.fetch!(term_ids, "call"))
      ])

    ids = OfflineFragments.finalize!(Exograph.DuckDBRepo, prefix)
    OfflineFragments.finalize_definitions!(Exograph.DuckDBRepo, prefix)
    OfflineFragments.finalize_references!(Exograph.DuckDBRepo, prefix)
    OfflineFragments.finalize_comments!(Exograph.DuckDBRepo, prefix)
    OfflineFragments.finalize_fragment_terms!(Exograph.DuckDBRepo, prefix)

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

    ids_again = OfflineFragments.finalize!(Exograph.DuckDBRepo, prefix)

    assert ids_again == ids
    assert fragment_count(prefix) == 2

    DuckDBSupport.drop_prefix(prefix)
    Exograph.DuckDBRepo.query!(~s|DROP TABLE IF EXISTS "#{prefix}_fragment_stage"|, [])
    Exograph.DuckDBRepo.query!(~s|DROP TABLE IF EXISTS "#{prefix}_definition_stage"|, [])
    Exograph.DuckDBRepo.query!(~s|DROP TABLE IF EXISTS "#{prefix}_reference_stage"|, [])
    Exograph.DuckDBRepo.query!(~s|DROP TABLE IF EXISTS "#{prefix}_comment_stage"|, [])
    Exograph.DuckDBRepo.query!(~s|DROP TABLE IF EXISTS "#{prefix}_term_stage"|, [])
    Exograph.DuckDBRepo.query!(~s|DROP TABLE IF EXISTS "#{prefix}_fragment_term_stage"|, [])
  end

  defp term_row(term), do: %{term: term}

  defp insert_file!(prefix, now) do
    %{rows: [[id]]} =
      Exograph.DuckDBRepo.query!(
        ~s|INSERT INTO "#{prefix}_files" (path, source, comments_text, sha256, inserted_at, updated_at) VALUES ('lib/sample.ex', '', '', 'sample-sha', ?, ?) RETURNING id|,
        [now, now]
      )

    id
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

  defp fragment_count(prefix) do
    %{rows: [[count]]} =
      Exograph.DuckDBRepo.query!(~s|SELECT count(*) FROM "#{prefix}_fragments"|, [])

    count
  end
end
