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
    assert file.identifier_tokens =~ "repo"
    assert file.identifier_tokens =~ "get"
    raw_ast = :erlang.binary_to_term(file.ast, [:safe])
    refute contains_atom?(raw_ast)
    assert {:defmodule, _, _} = Exograph.AST.Codec.load(file.ast)

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

  defp contains_atom?(term) when is_atom(term), do: true

  defp contains_atom?(term) when is_tuple(term) do
    term
    |> Tuple.to_list()
    |> Enum.any?(&contains_atom?/1)
  end

  defp contains_atom?(term) when is_list(term), do: Enum.any?(term, &contains_atom?/1)

  defp contains_atom?(term) when is_map(term),
    do: Enum.any?(term, fn {k, v} -> contains_atom?(k) or contains_atom?(v) end)

  defp contains_atom?(_term), do: false

  test "marks indexed package versions complete", %{prefix: prefix} do
    assert {:ok, _index} =
             Exograph.index_sources(
               [{"lib/demo/status.ex", "defmodule Demo.Status do\n  def run, do: :ok\nend"}],
               repo: Exograph.DuckDBRepo,
               prefix: prefix,
               migrate?: true,
               min_mass: 1,
               extractors: [:ex_ast],
               package_version: %{name: "demo", version: "1.0.0"}
             )

    [state] =
      Exograph.DuckDBRepo.all(
        from(version in Schema.package_versions_source(prefix), select: version.index_state)
      )

    assert state == "complete"
  end

  test "refuses indexes with an incompatible format", %{prefix: prefix} do
    Exograph.DuckDB.migrate!(repo: Exograph.DuckDBRepo, prefix: prefix)

    {1, nil} =
      Exograph.DuckDBRepo.update_all(
        Schema.index_format_source(prefix),
        set: [format_version: -1]
      )

    assert_raise ArgumentError, ~r/unsupported Exograph index format/, fn ->
      Exograph.index([], repo: Exograph.DuckDBRepo, prefix: prefix, migrate?: false)
    end
  end

  test "requires rebuilding v4 indexes before applying the v5 columnar format", %{
    prefix: prefix
  } do
    Exograph.DuckDB.migrate!(repo: Exograph.DuckDBRepo, prefix: prefix)

    {1, nil} =
      Exograph.DuckDBRepo.update_all(
        Schema.index_format_source(prefix),
        set: [format_version: 4]
      )

    assert_raise ArgumentError, ~r/unsupported Exograph index format 4\/1; reindex/, fn ->
      Exograph.DuckDB.migrate!(repo: Exograph.DuckDBRepo, prefix: prefix)
    end

    Exograph.DuckDBSupport.drop_prefix(prefix)
    Exograph.DuckDB.migrate!(repo: Exograph.DuckDBRepo, prefix: prefix)

    columns =
      Exograph.DuckDBRepo
      |> QuackDB.Meta.table_info!(Schema.table_name(prefix, :files))
      |> Enum.map(& &1.name)

    assert "identifier_tokens" in columns
  end

  test "schema drops persisted fragment AST and tree node table", %{prefix: prefix} do
    Exograph.DuckDB.migrate!(repo: Exograph.DuckDBRepo, prefix: prefix)

    columns =
      Exograph.DuckDBRepo
      |> QuackDB.Meta.table_info!(Schema.table_name(prefix, :fragments))
      |> Enum.map(& &1.name)

    refute "ast" in columns
    refute "terms" in columns
    assert "node_pre" in columns
    assert "node_post" in columns

    table_names =
      Exograph.DuckDBRepo
      |> QuackDB.Meta.tables!()
      |> Enum.map(& &1.name)

    refute "#{prefix}_tree_nodes" in table_names
  end
end
