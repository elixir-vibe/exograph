defmodule Exograph.DuckDB.CompactorTest do
  use ExUnit.Case, async: false

  alias Exograph.DuckDBShards

  test "compacts an offline manifest without changing query results" do
    directory =
      Path.join(System.tmp_dir!(), "exograph-compactor-#{System.unique_integer([:positive])}")

    port = Mix.Exograph.DuckDBOptions.free_tcp_port!()
    File.mkdir_p!(directory)

    on_exit(fn -> File.rm_rf(directory) end)

    {:ok, [shard]} =
      DuckDBShards.start_managed(1,
        directory: directory,
        prefix: "compact",
        port_base: port,
        duckdb_threads: 1,
        pool_size: 1
      )

    DuckDBShards.with_repo(shard, fn ->
      assert {:ok, _index} =
               Exograph.index_sources(
                 [
                   {"lib/compact.ex",
                    "defmodule Compact do\n  def run, do: Enum.map([], & &1)\nend"}
                 ],
                 repo: shard.repo,
                 dynamic_repo: shard.dynamic_repo,
                 prefix: shard.prefix,
                 migrate?: true,
                 min_mass: 1,
                 extractors: [:ex_ast]
               )

      Exograph.DuckDB.optimize_structural_indexes!(repo: shard.repo, prefix: shard.prefix)
      Exograph.DuckDB.optimize_structural_indexes!(repo: shard.repo, prefix: shard.prefix)
    end)

    manifest = DuckDBShards.manifest([shard], prefix: "compact")
    before_bytes = File.stat!(shard.database).size
    DuckDBShards.stop([shard])

    assert :ok = Exograph.DuckDB.Compactor.compact_manifest!(manifest)
    assert File.stat!(shard.database).size <= before_bytes

    {:ok, opened} = DuckDBShards.open(manifest, port_base: port, duckdb_threads: 1)

    on_exit(fn -> DuckDBShards.stop(opened) end)

    [opened_shard] = opened

    DuckDBShards.with_repo(opened_shard, fn ->
      {:ok, index} =
        Exograph.index([],
          repo: opened_shard.repo,
          prefix: opened_shard.prefix,
          migrate?: false
        )

      assert {:ok, [_hit | _]} = Exograph.search(index, "Enum.map(_, _)", limit: 5)
    end)
  end
end
