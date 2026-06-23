defmodule Exograph.Web.HealthTest do
  use ExUnit.Case, async: true

  alias Exograph.DuckDBShards
  alias Exograph.ShardedIndex
  alias Exograph.Web.Health

  test "reports unavailable when no index is open" do
    payload = Health.payload(nil)

    assert payload.status == "unavailable"
    assert payload.index.opened_shards == 0
    assert payload.application.name == "exograph"
  end

  test "reports sharded DuckDB manifest metadata" do
    manifest = %DuckDBShards.Manifest{
      version: 1,
      prefix: "hex",
      shard_count: 2,
      shards: [
        %DuckDBShards.Shard{id: 0, prefix: "hex_0", database: "/data/0.duckdb", packages: ["a"]},
        %DuckDBShards.Shard{
          id: 1,
          prefix: "hex_1",
          database: "/data/1.duckdb",
          packages: ["a", "b"]
        }
      ]
    }

    payload = Health.payload(%ShardedIndex{shards: [:left, :right], manifest: manifest})

    assert payload.status == "ok"
    assert payload.index.kind == "sharded_duckdb"
    assert payload.index.prefix == "hex"
    assert payload.index.shard_count == 2
    assert payload.index.opened_shards == 2
    assert payload.index.packages == 2
    assert Enum.map(payload.index.databases, & &1.id) == [0, 1]
  end
end
