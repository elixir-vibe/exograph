defmodule Exograph.Web.IndexStats do
  @moduledoc false

  alias Exograph.ShardedIndex
  alias Exograph.Storage.Schema

  def package_count(%ShardedIndex{shards: shards}) do
    Enum.sum_by(shards, &shard_package_count/1)
  rescue
    QuackDB.Error -> 0
  end

  def package_count(index) do
    prefix = index.inverted.prefix
    repo = index.inverted.repo

    repo.aggregate(Schema.packages_source(prefix), :count)
  rescue
    QuackDB.Error -> 0
  end

  defp shard_package_count(%{index: index} = shard) do
    Exograph.DuckDBShards.with_repo(shard, fn -> package_count(index) end)
  end

  defp shard_package_count(index), do: package_count(index)
end
