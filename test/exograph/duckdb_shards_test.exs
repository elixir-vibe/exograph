defmodule Exograph.DuckDBShardsTest do
  use ExUnit.Case, async: true

  alias Exograph.DuckDBShards
  alias Exograph.DuckDBShards.Shard

  test "manifest preserves shard package ownership metadata" do
    manifest =
      DuckDBShards.manifest(
        [
          %Shard{
            id: 0,
            prefix: "hex_0",
            database: "/data/hex_0.duckdb",
            packages: [%{name: "alpha", version: "1.0.0"}]
          },
          %Shard{
            id: 1,
            prefix: "hex_1",
            database: "/data/hex_1.duckdb",
            packages: [%{name: "beta", version: "2.0.0"}]
          }
        ],
        prefix: "hex"
      )

    assert %DuckDBShards.Manifest{prefix: "hex", shard_count: 2} = manifest

    assert Enum.map(manifest.shards, & &1.packages) == [
             [%{name: "alpha", version: "1.0.0"}],
             [%{name: "beta", version: "2.0.0"}]
           ]
  end

  test "stop terminates linked shard processes without exiting caller" do
    {:ok, repo} = Agent.start_link(fn -> :repo end)
    {:ok, server} = Agent.start_link(fn -> :server end)

    assert Process.alive?(repo)
    assert Process.alive?(server)

    assert :ok = DuckDBShards.stop(%{dynamic_repo: repo, server: server})

    refute Process.alive?(repo)
    refute Process.alive?(server)
  end

  test "stop accepts shard lists" do
    {:ok, repo} = Agent.start_link(fn -> :repo end)
    {:ok, server} = Agent.start_link(fn -> :server end)

    assert :ok = DuckDBShards.stop([%{dynamic_repo: repo, server: server}])

    refute Process.alive?(repo)
    refute Process.alive?(server)
  end

  test "manifest file round-trips package ownership metadata" do
    path =
      Path.join(System.tmp_dir!(), "exograph-shards-#{System.unique_integer([:positive])}.term")

    manifest =
      DuckDBShards.manifest(
        [
          %Shard{
            id: 0,
            prefix: "hex_0",
            database: "/data/hex_0.duckdb",
            packages: [%{name: "alpha", version: "1.0.0"}]
          }
        ],
        prefix: "hex"
      )

    File.write!(path, :erlang.term_to_binary(manifest))
    on_exit(fn -> File.rm(path) end)

    assert DuckDBShards.load_manifest(path) == manifest
  end
end
