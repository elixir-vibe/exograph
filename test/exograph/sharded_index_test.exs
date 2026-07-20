defmodule Exograph.ShardedIndexTest do
  use ExUnit.Case, async: false

  alias Exograph.DuckDBSupport
  alias Exograph.ShardedIndex
  alias Exograph.Web.IndexStats

  setup do
    endpoint = "quack:127.0.0.1:#{Mix.Exograph.DuckDBOptions.free_tcp_port!()}"
    database = DuckDBSupport.start_managed_repo!(endpoint: endpoint)

    on_exit(fn ->
      File.rm(database)
      File.rm(database <> ".wal")
    end)

    :ok
  end

  test "sharded fanout emits per-shard telemetry" do
    alpha_path =
      fixture("telemetry_alpha.ex", """
      defmodule Demo.TelemetryAlpha do
        def alpha_value do
          :alpha
        end
      end
      """)

    beta_path =
      fixture("telemetry_beta.ex", """
      defmodule Demo.TelemetryBeta do
        def beta_value do
          :beta
        end
      end
      """)

    {:ok, alpha_index} =
      Exograph.index(alpha_path,
        repo: Exograph.DuckDBRepo,
        prefix: "telemetry_alpha",
        migrate?: true,
        min_mass: 4
      )

    {:ok, beta_index} =
      Exograph.index(beta_path,
        repo: Exograph.DuckDBRepo,
        prefix: "telemetry_beta",
        migrate?: true,
        min_mass: 4
      )

    sharded =
      ShardedIndex.new([
        %{id: 0, prefix: "telemetry_alpha", index: alpha_index},
        %{id: 1, prefix: "telemetry_beta", index: beta_index}
      ])

    handler_id = {__MODULE__, self(), make_ref()}

    :telemetry.attach(
      handler_id,
      [:exograph, :shard, :query, :stop],
      &__MODULE__.handle_event/4,
      self()
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    assert {:ok, [_hit | _]} = Exograph.search(sharded, "def alpha_value do ... end", limit: 10)

    assert_receive {:shard_query_stop, measurements, metadata}
    assert is_float(measurements.duration_ms)
    assert metadata.function == :search
    assert metadata.status == :ok
    assert metadata.shard_id in [0, 1]
    assert metadata.shard_prefix in ["telemetry_alpha", "telemetry_beta"]
  end

  test "public entity queries and hydration work across shards" do
    {:ok, alpha_index} = index_public_package("public_alpha", "alpha", "1.0.0", true)
    {:ok, _charlie_index} = index_public_package("public_alpha", "charlie", "3.0.0", false)
    {:ok, _echo_index} = index_public_package("public_alpha", "echo", "5.0.0", false)

    {:ok, beta_index} = index_public_package("public_beta", "beta", "2.0.0", true)
    {:ok, _delta_index} = index_public_package("public_beta", "delta", "4.0.0", false)
    {:ok, _foxtrot_index} = index_public_package("public_beta", "foxtrot", "6.0.0", false)

    alpha_packages = [
      %{name: "alpha", version: "1.0.0"},
      %{name: "charlie", version: "3.0.0"},
      %{name: "echo", version: "5.0.0"}
    ]

    beta_packages = [
      %{name: "beta", version: "2.0.0"},
      %{name: "delta", version: "4.0.0"},
      %{name: "foxtrot", version: "6.0.0"}
    ]

    sharded =
      ShardedIndex.new([
        %{index: alpha_index, packages: alpha_packages},
        %{index: beta_index, packages: beta_packages}
      ])

    package_query = %Exograph.Query{source: :package, binding: "p"}

    assert {:ok, packages} = Exograph.all(sharded, package_query, limit: 10)
    assert Enum.map(packages, & &1.name) == ~w(alpha beta charlie delta echo foxtrot)

    assert {:ok, page_one} = Exograph.all(sharded, package_query, limit: 2)
    assert {:ok, page_two} = Exograph.all(sharded, package_query, limit: 2, skip: 2)
    assert {:ok, page_three} = Exograph.all(sharded, package_query, limit: 2, skip: 4)

    assert Enum.map(page_one ++ page_two ++ page_three, & &1.name) ==
             ~w(alpha beta charlie delta echo foxtrot)

    version_query = %Exograph.Query{source: :package_version, binding: "v"}

    assert {:ok, version_page} = Exograph.all(sharded, version_query, limit: 3, skip: 2)
    assert Enum.map(version_page, & &1.package_name) == ~w(charlie delta echo)

    assert {:ok, 6} = Exograph.count(sharded, package_query)

    assert {:ok, %Exograph.Query.Estimate{value: 6, relation: :eq}} =
             Exograph.estimate_candidates(sharded, package_query)

    version = Exograph.PackageVersion.new(name: "beta", version: "2.0.0")
    assert {:ok, snapshot} = Exograph.hydrate(sharded, version)
    assert snapshot.package_version.package_name == "beta"
    assert Enum.map(snapshot.files, & &1.path) == ["lib/beta.ex"]
  end

  test "package-scoped sharded search routes to the matching shard" do
    alpha_path =
      fixture("alpha.ex", """
      defmodule Demo.Alpha do
        def only_alpha(value) do
          {:alpha, value}
        end
      end
      """)

    beta_path =
      fixture("beta.ex", """
      defmodule Demo.Beta do
        def only_beta(value) do
          {:beta, value}
        end
      end
      """)

    {:ok, alpha_index} =
      Exograph.index(alpha_path,
        repo: Exograph.DuckDBRepo,
        prefix: "sharded_alpha",
        migrate?: true,
        min_mass: 4,
        package: %{name: "alpha"},
        package_version: %{name: "alpha", version: "1.0.0"}
      )

    {:ok, beta_index} =
      Exograph.index(beta_path,
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

    alpha_filter = %{name: "alpha", version: "1.0.0"}
    beta_filter = %{name: "beta", version: "1.0.0"}

    assert {:ok, [_alpha_hit | _]} =
             Exograph.search_text(sharded, "alpha",
               package_version: alpha_filter,
               limit: 10
             )

    assert {:ok, [_alpha_hit | _]} =
             Exograph.search_text(sharded, "alpha",
               package_version: %Exograph.PackageVersion{package_name: "alpha", version: "1.0.0"},
               limit: 10
             )

    assert {:ok, []} =
             Exograph.search_text(sharded, "alpha",
               package_version: beta_filter,
               limit: 10
             )

    sharded_with_missing_manifest_package =
      ShardedIndex.new([
        %{index: alpha_index, packages: [%{name: "missing", version: "9.9.9"}]}
      ])

    assert {:ok, []} =
             Exograph.search_text(sharded_with_missing_manifest_package, "alpha",
               package_version: %{name: "missing", version: "9.9.9"},
               limit: 10
             )

    assert IndexStats.package_count(sharded) == 2
  end

  test "package-scoped sharded text search matches a single logical DuckDB index" do
    alpha_path =
      fixture("single_alpha.ex", """
      defmodule Demo.SingleAlpha do
        def alpha_value do
          :alpha
        end
      end
      """)

    beta_path =
      fixture("single_beta.ex", """
      defmodule Demo.SingleBeta do
        def beta_value do
          :beta
        end
      end
      """)

    {:ok, single_alpha_index} =
      Exograph.index(alpha_path,
        repo: Exograph.DuckDBRepo,
        prefix: "single_package_parity",
        migrate?: true,
        min_mass: 4,
        package: %{name: "alpha"},
        package_version: %{name: "alpha", version: "1.0.0"}
      )

    {:ok, _single_beta_index} =
      Exograph.index(beta_path,
        repo: Exograph.DuckDBRepo,
        prefix: "single_package_parity",
        migrate?: false,
        min_mass: 4,
        package: %{name: "beta"},
        package_version: %{name: "beta", version: "1.0.0"}
      )

    {:ok, single_index} =
      Exograph.index([],
        repo: Exograph.DuckDBRepo,
        prefix: "single_package_parity",
        migrate?: false
      )

    {:ok, sharded_alpha_index} =
      Exograph.index(alpha_path,
        repo: Exograph.DuckDBRepo,
        prefix: "sharded_parity_alpha",
        migrate?: true,
        min_mass: 4,
        package: %{name: "alpha"},
        package_version: %{name: "alpha", version: "1.0.0"}
      )

    {:ok, sharded_beta_index} =
      Exograph.index(beta_path,
        repo: Exograph.DuckDBRepo,
        prefix: "sharded_parity_beta",
        migrate?: true,
        min_mass: 4,
        package: %{name: "beta"},
        package_version: %{name: "beta", version: "1.0.0"}
      )

    sharded_index =
      ShardedIndex.new([
        %{index: sharded_alpha_index, packages: [%{name: "alpha", version: "1.0.0"}]},
        %{index: sharded_beta_index, packages: [%{name: "beta", version: "1.0.0"}]}
      ])

    alpha_id = single_alpha_index.fragment_store.package_version.id

    assert {:ok, single_hits} =
             Exograph.search_text(single_index, "alpha", package_version_id: alpha_id, limit: 10)

    assert {:ok, sharded_hits} =
             Exograph.search_text(sharded_index, "alpha",
               package_version: %{name: "alpha", version: "1.0.0"},
               limit: 10
             )

    assert length(sharded_hits) == length(single_hits)
  end

  test "opened manifests preserve package-scoped routing" do
    shard_dir =
      Path.join(
        System.tmp_dir!(),
        "exograph-sharded-manifest-#{System.unique_integer([:positive])}"
      )

    port_base = 18_000 + rem(System.unique_integer([:positive]), 20_000)

    {:ok, shards} =
      Exograph.DuckDBShards.start_managed(2,
        directory: shard_dir,
        prefix: "manifest_shard",
        port_base: port_base,
        pool_size: 1,
        duckdb_threads: 2
      )

    on_exit(fn -> File.rm_rf(shard_dir) end)

    alpha_path =
      fixture("manifest_alpha.ex", """
      defmodule Demo.ManifestAlpha do
        def manifest_alpha do
          :alpha
        end
      end
      """)

    beta_path =
      fixture("manifest_beta.ex", """
      defmodule Demo.ManifestBeta do
        def manifest_beta do
          :beta
        end
      end
      """)

    [alpha_shard, beta_shard] = shards

    Exograph.DuckDBShards.with_repo(alpha_shard, fn ->
      {:ok, _index} =
        Exograph.index(alpha_path,
          repo: alpha_shard.repo,
          prefix: alpha_shard.prefix,
          migrate?: true,
          min_mass: 4,
          package: %{name: "alpha"},
          package_version: %{name: "alpha", version: "1.0.0"}
        )
    end)

    Exograph.DuckDBShards.with_repo(beta_shard, fn ->
      {:ok, _index} =
        Exograph.index(beta_path,
          repo: beta_shard.repo,
          prefix: beta_shard.prefix,
          migrate?: true,
          min_mass: 4,
          package: %{name: "beta"},
          package_version: %{name: "beta", version: "1.0.0"}
        )
    end)

    manifest =
      Exograph.DuckDBShards.manifest(
        [
          %{alpha_shard | packages: [%{name: "alpha", version: "1.0.0"}]},
          %{beta_shard | packages: [%{name: "beta", version: "1.0.0"}]}
        ],
        prefix: "manifest_shard"
      )

    assert :ok = Exograph.DuckDBShards.stop(shards)

    {:ok, opened} =
      Exograph.open_sharded(manifest,
        port_base: port_base + 100,
        pool_size: 1,
        duckdb_threads: 2
      )

    on_exit(fn -> Exograph.DuckDBShards.stop(opened.shards) end)

    assert {:ok, [_alpha_hit | _]} =
             Exograph.search_text(opened, "alpha",
               package_version: %{name: "alpha", version: "1.0.0"},
               limit: 10
             )

    assert {:ok, []} =
             Exograph.search_text(opened, "alpha",
               package_version: %{name: "beta", version: "1.0.0"},
               limit: 10
             )
  end

  test "sharded DSL queries apply limit and skip globally" do
    alpha_path =
      fixture("limit_alpha.ex", """
      defmodule Demo.LimitAlpha do
        def alpha_one, do: :alpha
      end
      """)

    beta_path =
      fixture("limit_beta.ex", """
      defmodule Demo.LimitBeta do
        def beta_one, do: :beta
      end
      """)

    {:ok, alpha_index} =
      Exograph.index(alpha_path,
        repo: Exograph.DuckDBRepo,
        prefix: "sharded_limit_alpha",
        migrate?: true,
        min_mass: 4,
        package: %{name: "alpha"},
        package_version: %{name: "alpha", version: "1.0.0"}
      )

    {:ok, beta_index} =
      Exograph.index(beta_path,
        repo: Exograph.DuckDBRepo,
        prefix: "sharded_limit_beta",
        migrate?: true,
        min_mass: 4,
        package: %{name: "beta"},
        package_version: %{name: "beta", version: "1.0.0"}
      )

    query = %Exograph.Query{
      source: :fragment,
      binding: "f",
      predicates: [
        %Exograph.Query.Predicate{op: :matches, binding: "f", value: "def _ do ... end"}
      ]
    }

    sharded = ShardedIndex.new([alpha_index, beta_index])

    assert {:ok, [_first, second]} = Exograph.all(sharded, query, limit: 2)
    assert {:ok, [page_two]} = Exograph.all(sharded, query, limit: 1, skip: 1)
    assert page_two.fragment.id == second.fragment.id
  end

  def handle_event(_event, measurements, metadata, test_pid) do
    send(test_pid, {:shard_query_stop, measurements, metadata})
  end

  defp index_public_package(prefix, name, version, migrate?) do
    Exograph.index_sources(
      [{"lib/#{name}.ex", "defmodule #{Macro.camelize(name)} do\nend\n"}],
      DuckDBSupport.opts(prefix,
        extractors: [:ex_ast],
        min_mass: 1,
        migrate?: migrate?,
        package: %{name: name},
        package_version: %{name: name, version: version}
      )
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
