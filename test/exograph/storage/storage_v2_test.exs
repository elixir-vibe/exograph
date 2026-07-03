defmodule Exograph.Storage.StorageV2Test do
  use ExUnit.Case, async: false

  import Ecto.Query

  alias Exograph.Storage.{FragmentRecord, Schema}

  setup do
    Exograph.DuckDBSupport.start_managed_repo!()
    prefix = "storage_v2_#{System.unique_integer([:positive])}"

    on_exit(fn -> Exograph.DuckDBSupport.drop_prefix(prefix) end)

    {:ok, prefix: prefix}
  end

  test "stores whole-file AST once and hydrates fragments by locator", %{prefix: prefix} do
    source = """
    defmodule Demo.StorageV2 do
      def call(value) do
        Repo.get!(User, value)
      end
    end
    """

    assert {:ok, index} =
             Exograph.index_sources([{"lib/demo/storage_v2.ex", source}],
               repo: Exograph.DuckDBRepo,
               prefix: prefix,
               migrate?: true,
               min_mass: 1,
               extractors: [:ex_ast]
             )

    [file] = Exograph.DuckDBRepo.all(Schema.files_source(prefix))
    assert is_binary(file.ast)
    assert {:defmodule, _, _} = :erlang.binary_to_term(file.ast, [:safe])

    fragment_rows =
      Exograph.DuckDBRepo.all(
        from(fragment in {Schema.fragments_source(prefix), FragmentRecord},
          select: map(fragment, [:id, :node_pre, :node_post, :kind, :name])
        )
      )

    assert fragment_rows != []
    assert Enum.all?(fragment_rows, &(is_integer(&1.node_pre) and is_integer(&1.node_post)))

    assert {:ok, hits} = Exograph.search(index, "Repo.get!(_, _)", limit: 5)
    assert [%Exograph.Hit{fragment: fragment} | _] = hits
    assert fragment.ast != nil
    assert fragment.node_pre != nil
    assert fragment.node_post != nil
  end

  test "schema drops persisted fragment AST and tree node table", %{prefix: prefix} do
    Exograph.DuckDB.migrate!(repo: Exograph.DuckDBRepo, prefix: prefix)

    columns =
      Exograph.DuckDBRepo.query!("DESCRIBE #{Schema.table_name(prefix, :fragments)}", []).rows
      |> Enum.map(fn [name | _] -> name end)

    refute "ast" in columns
    refute "terms" in columns
    assert "node_pre" in columns
    assert "node_post" in columns

    table_names =
      Exograph.DuckDBRepo.query!("SHOW TABLES", []).rows
      |> List.flatten()

    refute "#{prefix}_tree_nodes" in table_names
  end
end
