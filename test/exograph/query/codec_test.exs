defmodule Exograph.Query.CodecTest do
  use ExUnit.Case, async: true

  alias Exograph.Query.{Estimate, Join, Plan, Predicate}

  test "round-trips every public query and hydration contract" do
    predicate = %Predicate{op: :eq, binding: "p", field: :name, value: "demo"}
    join = %Join{parent: "f", binding: "d", association: :definitions}

    query = %Exograph.Query{
      source: :package,
      binding: "p",
      predicates: [predicate],
      joins: []
    }

    package = %Exograph.Package{id: 1, ecosystem: "hex", name: "demo", metadata: %{}}

    version = %Exograph.PackageVersion{
      id: 2,
      package_id: 1,
      ecosystem: "hex",
      package_name: "demo",
      version: "1.0.0",
      metadata: %{}
    }

    file_ref = %Exograph.FileRef{
      id: 3,
      package_id: 1,
      package_version_id: 2,
      path: "lib/demo.ex",
      sha256: "abc"
    }

    file = %Exograph.File{
      id: 3,
      package_id: 1,
      package_version_id: 2,
      path: "lib/demo.ex",
      source: "defmodule Demo do\nend\n",
      ast: nil,
      comments_text: "",
      identifier_tokens: "defmodule demo",
      sha256: "abc"
    }

    snapshot = %Exograph.SourceSnapshot{
      package_version: version,
      files: [file],
      fingerprint: "fingerprint",
      complete: true,
      provenance: %{"index_prefix" => "test"}
    }

    estimate = %Estimate{value: 12, relation: :eq}

    plan = %Plan{
      query: query,
      execution: :relational,
      hydration: :none,
      required_terms: []
    }

    contracts = [
      {Predicate, predicate},
      {Join, join},
      {Exograph.Query, query},
      {Plan, plan},
      {Estimate, estimate},
      {Exograph.Package, package},
      {Exograph.PackageVersion, version},
      {Exograph.FileRef, file_ref},
      {Exograph.File, file},
      {Exograph.SourceSnapshot, snapshot}
    ]

    Enum.each(contracts, fn {module, contract} ->
      assert {:ok, ^contract} = apply(module, :from_map, [JSONCodec.dump(contract)])
    end)
  end
end
