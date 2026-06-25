defmodule Exograph.Storage.FragmentStoreTest do
  use ExUnit.Case, async: true

  alias Exograph.Storage.FragmentStore

  test "DuckDB fragment append defaults to Ecto append" do
    assert {:ok, %FragmentStore{duckdb_fragment_append: :ecto}} =
             FragmentStore.new(repo: Exograph.DuckDBRepo, migrate?: false)
  end
end
