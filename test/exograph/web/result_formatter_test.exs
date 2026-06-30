defmodule Exograph.Web.ResultFormatterTest do
  use ExUnit.Case, async: true

  alias Exograph.{Fragment, Hit}
  alias Exograph.Web.ResultFormatter

  test "groups results by package version" do
    results = [
      hit("lib/demo.ex", "demo", "1.0.0", 4),
      hit("lib/demo.ex", "demo", "1.1.0", 4)
    ]

    groups = ResultFormatter.format(results)

    assert Enum.map(groups, &{&1.package, &1.package_version, &1.key}) == [
             {"demo", "1.0.0", "demo@1.0.0"},
             {"demo", "1.1.0", "demo@1.1.0"}
           ]

    assert Enum.all?(groups, &(&1.count == 1))
  end

  defp hit(file, package, package_version, line) do
    %Hit{
      fragment: %Fragment{
        file: file,
        package: package,
        package_version: package_version,
        kind: :def,
        name: "run",
        arity: 0,
        line: line,
        source: "def run, do: :ok"
      },
      match: nil
    }
  end
end
