defmodule ExographShardedSemanticsTest do
  use ExUnit.Case, async: false

  alias Exograph.DuckDBSupport
  alias Exograph.ShardedIndex

  setup do
    endpoint = "quack:127.0.0.1:#{Mix.Exograph.BackendOptions.free_tcp_port!()}"
    database = DuckDBSupport.start_managed_repo!(endpoint: endpoint)

    on_exit(fn ->
      File.rm(database)
      File.rm(database <> ".wal")
    end)

    :ok
  end

  test "package-scoped sharded search routes to the matching shard" do
    alpha_path =
      fixture("alpha.ex", """
      defmodule Demo.Alpha do
        def only_alpha(value), do: {:alpha, value}
      end
      """)

    beta_path =
      fixture("beta.ex", """
      defmodule Demo.Beta do
        def only_beta(value), do: {:beta, value}
      end
      """)

    {:ok, alpha_index} =
      Exograph.index(alpha_path,
        backend: :duckdb,
        repo: Exograph.DuckDBRepo,
        prefix: "sharded_alpha",
        migrate?: true,
        min_mass: 4,
        package: %{name: "alpha"},
        package_version: %{name: "alpha", version: "1.0.0"}
      )

    {:ok, beta_index} =
      Exograph.index(beta_path,
        backend: :duckdb,
        repo: Exograph.DuckDBRepo,
        prefix: "sharded_beta",
        migrate?: true,
        min_mass: 4,
        package: %{name: "beta"},
        package_version: %{name: "beta", version: "1.0.0"}
      )

    sharded =
      ShardedIndex.new([
        %{index: alpha_index, packages: [%{name: "alpha", version: "1.0.0"}]},
        %{index: beta_index, packages: [%{name: "beta", version: "1.0.0"}]}
      ])

    assert {:ok, [_alpha_hit | _]} =
             Exograph.search_text(sharded, "alpha",
               package_version: %{name: "alpha", version: "1.0.0"},
               limit: 10
             )

    assert {:ok, [_alpha_hit | _]} =
             Exograph.search_text(sharded, "alpha",
               package_version: %Exograph.PackageVersion{package_name: "alpha", version: "1.0.0"},
               limit: 10
             )

    assert {:ok, []} =
             Exograph.search_text(sharded, "alpha",
               package_version: %{name: "beta", version: "1.0.0"},
               limit: 10
             )
  end

  defp fixture(name, source) do
    dir =
      Path.join(
        System.tmp_dir!(),
        "exograph-sharded-semantics-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    path = Path.join(dir, name)
    File.write!(path, source)
    path
  end
end
