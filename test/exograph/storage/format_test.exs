defmodule Exograph.Storage.FormatTest do
  use ExUnit.Case, async: false

  alias Exograph.DuckDBShards
  alias Exograph.Storage.{Format, Schema}

  setup do
    Exograph.DuckDBSupport.start_managed_repo!()
    prefix = "storage_format_#{System.unique_integer([:positive])}"

    on_exit(fn -> Exograph.DuckDBSupport.drop_prefix(prefix) end)

    {:ok, prefix: prefix, repo: Exograph.DuckDBRepo}
  end

  test "migration writes current storage schema version", %{prefix: prefix, repo: repo} do
    Exograph.DuckDB.migrate!(repo: repo, prefix: prefix)

    versions = repo.all(Schema.source(:schema_migrations, prefix)) |> Enum.map(& &1.version)

    assert versions == [Format.current_schema_version()]
  end

  test "v1-only prefixes are refused before migration/open", %{prefix: prefix, repo: repo} do
    create_legacy_schema_migrations!(repo, prefix)

    assert_raise ArgumentError, ~r/refusing to open Exograph index prefix/, fn ->
      Exograph.DuckDB.migrate!(repo: repo, prefix: prefix)
    end

    assert_raise ArgumentError, ~r/refusing to open Exograph index prefix/, fn ->
      Exograph.index([], repo: repo, prefix: prefix, migrate?: false)
    end
  end

  test "old shard manifests are refused", %{prefix: prefix} do
    manifest = %DuckDBShards.Manifest{version: 1, prefix: prefix, shard_count: 0, shards: []}

    assert_raise ArgumentError, ~r/refusing to open Exograph shard manifest version 1/, fn ->
      DuckDBShards.open(manifest)
    end
  end

  defp create_legacy_schema_migrations!(repo, prefix) do
    source = Schema.table_name(prefix, :schema_migrations)

    repo.query!("CREATE TABLE #{source} (version BIGINT PRIMARY KEY)", [])
    repo.insert_all(Schema.source(:schema_migrations, prefix), [%{version: 1}])
  end
end
