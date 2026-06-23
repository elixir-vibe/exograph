defmodule Exograph.Storage.FragmentStoreTest do
  use ExUnit.Case, async: true

  alias Exograph.Storage.FragmentStore

  test "DuckDB fragment append defaults to MERGE" do
    assert {:ok, %FragmentStore{duckdb_fragment_append: :merge}} =
             FragmentStore.new(repo: Exograph.DuckDBRepo, migrate?: false)
  end
end
