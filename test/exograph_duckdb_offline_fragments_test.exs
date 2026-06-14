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

    rows = [
      fragment_row(<<1>>, "first", 1, now),
      fragment_row(<<1>>, "duplicate", 2, now),
      fragment_row(<<2>>, "second", 3, now)
    ]

    OfflineFragments.create_stage!(Exograph.DuckDBRepo, prefix)
    {_count, _rows} = OfflineFragments.append_stage!(Exograph.DuckDBRepo, prefix, rows)

    ids = OfflineFragments.finalize!(Exograph.DuckDBRepo, prefix)

    assert map_size(ids) == 2
    assert Map.has_key?(ids, <<1>>)
    assert Map.has_key?(ids, <<2>>)
    assert fragment_count(prefix) == 2

    ids_again = OfflineFragments.finalize!(Exograph.DuckDBRepo, prefix)

    assert ids_again == ids
    assert fragment_count(prefix) == 2

    DuckDBSupport.drop_prefix(prefix)
    Exograph.DuckDBRepo.query!(~s|DROP TABLE IF EXISTS "#{prefix}_fragment_stage"|, [])
  end

  defp fragment_row(content_hash, name, line, now) do
    %{
      package_id: nil,
      package_version_id: nil,
      file_id: nil,
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

  defp fragment_count(prefix) do
    %{rows: [[count]]} =
      Exograph.DuckDBRepo.query!(~s|SELECT count(*) FROM "#{prefix}_fragments"|, [])

    count
  end
end
