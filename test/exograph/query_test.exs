defmodule Exograph.QueryTest do
  use ExUnit.Case, async: false

  import Exograph.DSL

  alias Exograph.DuckDBSupport

  setup do
    prefix = "query_#{System.unique_integer([:positive])}"

    index =
      DuckDBSupport.start_index!(
        prefix,
        [
          {"lib/demo.ex", "defmodule Demo do\n  def run, do: :ok\nend\n"},
          {"priv/seed.exs", "IO.puts(\"seed\")\n"}
        ],
        extractors: [:ex_ast],
        min_mass: 1,
        package: %{name: "demo"},
        package_version: %{name: "demo", version: "1.0.0"}
      )

    {:ok, index: index}
  end

  test "queries first-class package entities", %{index: index} do
    package_query = from(p in Exograph.Package, where: p.name == "demo")
    version_query = from(v in Exograph.PackageVersion, where: v.version == "1.0.0")
    file_query = from(f in Exograph.File, where: prefix_search(f.path, "lib/"))

    assert {:ok, [%Exograph.Package{name: "demo"}]} = Exograph.all(index, package_query)

    assert {:ok, [%Exograph.PackageVersion{package_name: "demo", version: "1.0.0"}]} =
             Exograph.all(index, version_query)

    assert {:ok, [%Exograph.FileRef{path: "lib/demo.ex"}]} = Exograph.all(index, file_query)
    assert {:ok, 1} = Exograph.count(index, package_query)
  end

  test "round-trips through JSONCodec", %{index: index} do
    query = from(v in Exograph.PackageVersion, where: v.version == "1.0.0")
    encoded = JSONCodec.dump(query)

    assert {:ok, ^query} = Exograph.Query.from_map(encoded)
    assert {:ok, [%Exograph.PackageVersion{version: "1.0.0"}]} = Exograph.all(index, query)
  end

  test "rejects unsupported versions" do
    query = %Exograph.Query{version: 2, source: :package, binding: "p"}

    assert {:error, {:unsupported_query_version, 2}} = Exograph.Query.validate(query)
    assert_raise ArgumentError, fn -> Exograph.plan(query) end
  end

  test "estimates relational and indexed structural candidates", %{index: index} do
    package_query = from(p in Exograph.Package, where: p.name == "demo")
    fragment_query = from(f in Exograph.Fragment, where: contains(f, "def run, do: _"))

    assert {:ok, %Exograph.Query.Estimate{value: 1, relation: :eq}} =
             Exograph.estimate_candidates(index, package_query)

    assert {:ok, %Exograph.Query.Estimate{value: candidates, relation: :eq}} =
             Exograph.estimate_candidates(index, fragment_query)

    assert candidates >= 1
  end

  test "produces serializable logical plans and explanations", %{index: index} do
    query = from(f in Exograph.Fragment, where: contains(f, "Enum.map(_, _)"))

    plan = Exograph.plan(query)
    assert %Exograph.Query.Plan{execution: :indexed_structural} = plan
    assert {:ok, ^plan} = plan |> JSONCodec.dump() |> Exograph.Query.Plan.from_map()

    assert %{
             query: ^query,
             execution: :indexed_structural,
             required_terms: terms,
             index: %{prefix: _prefix}
           } = Exograph.explain(index, query)

    assert is_list(terms)
  end
end
