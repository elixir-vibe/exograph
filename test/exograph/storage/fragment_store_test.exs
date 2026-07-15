defmodule Exograph.Storage.FragmentStoreTest do
  use ExUnit.Case, async: false

  import Ecto.Query

  alias Exograph.Storage.{FragmentRecord, FragmentStore, Schema}

  setup do
    Exograph.DuckDBSupport.start_managed_repo!()
    prefix = "fragment_store_#{System.unique_integer([:positive])}"

    on_exit(fn -> Exograph.DuckDBSupport.drop_prefix(prefix) end)

    {:ok, prefix: prefix}
  end

  test "deletes every persisted row for an incomplete package version", %{prefix: prefix} do
    source =
      "defmodule Cleanup.Sample do\n  def run(value), do: Enum.map(value, &to_string/1)\nend"

    assert {:ok, _index} =
             Exograph.index_sources([{"lib/cleanup/sample.ex", source}],
               repo: Exograph.DuckDBRepo,
               prefix: prefix,
               migrate?: true,
               min_mass: 1,
               extractors: [:ex_ast, :reach],
               package_version: %{name: "cleanup", version: "1.0.0"}
             )

    package_version_id =
      Exograph.DuckDBRepo.one!(
        from(version in Schema.package_versions_source(prefix), select: version.id)
      )

    fragment_ids =
      Exograph.DuckDBRepo.all(
        from(fragment in {Schema.fragments_source(prefix), FragmentRecord},
          where: fragment.package_version_id == ^package_version_id,
          select: fragment.id
        )
      )

    Exograph.DuckDBRepo.update_all(
      from(version in Schema.package_versions_source(prefix),
        where: version.id == ^package_version_id
      ),
      set: [index_state: "pending"]
    )

    assert :ok =
             FragmentStore.delete_incomplete_package_version(
               Exograph.DuckDBRepo,
               prefix,
               "cleanup",
               "1.0.0"
             )

    assert Exograph.DuckDBRepo.aggregate(Schema.package_versions_source(prefix), :count) == 0
    assert Exograph.DuckDBRepo.aggregate(Schema.files_source(prefix), :count) == 0

    assert Exograph.DuckDBRepo.aggregate(
             {Schema.fragments_source(prefix), FragmentRecord},
             :count
           ) == 0

    assert Exograph.DuckDBRepo.aggregate(
             from(term in Schema.fragment_terms_source(prefix),
               where: term.fragment_id in ^fragment_ids
             ),
             :count
           ) == 0

    Enum.each([:comments, :definitions, :references, :graph_nodes, :call_edges], fn table ->
      assert Exograph.DuckDBRepo.aggregate(Schema.source(table, prefix), :count) == 0
    end)
  end
end
