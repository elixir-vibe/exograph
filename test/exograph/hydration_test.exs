defmodule Exograph.HydrationTest do
  use ExUnit.Case, async: false

  import Exograph.DSL

  alias Exograph.DuckDBSupport

  setup do
    prefix = "hydration_#{System.unique_integer([:positive])}"

    index =
      DuckDBSupport.start_index!(
        prefix,
        [{"lib/demo.ex", "defmodule Demo do\n  def run, do: :ok\nend\n"}],
        extractors: [:ex_ast],
        min_mass: 1,
        package: %{name: "demo"},
        package_version: %{name: "demo", version: "1.0.0"}
      )

    query = from(v in Exograph.PackageVersion, where: v.version == "1.0.0")
    {:ok, [version]} = Exograph.all(index, query)

    {:ok, index: index, version: version}
  end

  test "hydrates reproducible package source snapshots", %{index: index, version: version} do
    assert {:ok, snapshot} = Exograph.hydrate(index, version)
    assert snapshot.package_version.package_name == "demo"
    assert snapshot.complete
    assert Enum.map(snapshot.files, & &1.path) == ["lib/demo.ex"]
    assert Enum.all?(snapshot.files, &is_nil(&1.ast))

    assert {:ok, with_ast} = Exograph.hydrate(index, version, include_ast: true)
    assert Enum.all?(with_ast.files, &(not is_nil(&1.ast)))
    assert with_ast.fingerprint == snapshot.fingerprint
  end
end
