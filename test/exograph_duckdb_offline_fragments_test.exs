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

    {_count, _rows} = OfflineFragments.append_stage!(Exograph.DuckDBRepo, prefix, rows)

    {_count, _rows} =
      OfflineFragments.append_definition_stage!(Exograph.DuckDBRepo, prefix, [
        definition_row(<<1>>, "first/0", file_id, 1, now),
        definition_row(<<2>>, "second/0", file_id, 3, now)
      ])

    ids = OfflineFragments.finalize!(Exograph.DuckDBRepo, prefix)
    OfflineFragments.finalize_definitions!(Exograph.DuckDBRepo, prefix)

    assert map_size(ids) == 2
    assert Map.has_key?(ids, <<1>>)
    assert Map.has_key?(ids, <<2>>)
    assert fragment_count(prefix) == 2

    assert definitions(prefix) == [
             {"first/0", Map.fetch!(ids, <<1>>)},
             {"second/0", Map.fetch!(ids, <<2>>)}
           ]

    ids_again = OfflineFragments.finalize!(Exograph.DuckDBRepo, prefix)

    assert ids_again == ids
    assert fragment_count(prefix) == 2

    DuckDBSupport.drop_prefix(prefix)
    Exograph.DuckDBRepo.query!(~s|DROP TABLE IF EXISTS "#{prefix}_fragment_stage"|, [])
    Exograph.DuckDBRepo.query!(~s|DROP TABLE IF EXISTS "#{prefix}_definition_stage"|, [])
  end

  defp insert_file!(prefix, now) do
    %{rows: [[id]]} =
      Exograph.DuckDBRepo.query!(
        ~s|INSERT INTO "#{prefix}_files" (path, source, comments_text, sha256, inserted_at, updated_at) VALUES ('lib/sample.ex', '', '', 'sample-sha', ?, ?) RETURNING id|,
        [now, now]
      )

    id
  end

  defp definition_row(fragment_content_hash, qualified_name, file_id, line, now) do
    %{
      package_id: nil,
      package_version_id: nil,
      file_id: file_id,
      kind: "def",
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

  defp definitions(prefix) do
    %{rows: rows} =
      Exograph.DuckDBRepo.query!(
        ~s|SELECT qualified_name, fragment_id FROM "#{prefix}_definitions" ORDER BY qualified_name|,
        []
      )

    Enum.map(rows, fn [qualified_name, fragment_id] -> {qualified_name, fragment_id} end)
  end

  defp fragment_count(prefix) do
    %{rows: [[count]]} =
      Exograph.DuckDBRepo.query!(~s|SELECT count(*) FROM "#{prefix}_fragments"|, [])

    count
  end
end
