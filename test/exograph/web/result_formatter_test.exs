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

  test "links files and results to exact Hex Preview source lines" do
    [group] = ResultFormatter.format([hit("lib/path with spaces/demo.ex", "demo", "1.0.0", 42)])
    [file_group] = group.files
    [result] = file_group.results

    assert file_group.source_url ==
             "https://preview.hex.pm/preview/demo/1.0.0/show/lib/path%20with%20spaces/demo.ex"

    assert result.source_url == file_group.source_url <> "#L42"
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
        source: source_with_line(line)
      },
      match: nil
    }
  end

  defp source_with_line(line) do
    1..max(line, 1)
    |> Enum.map(fn current_line ->
      if current_line == line, do: "def run, do: :ok", else: "# line #{current_line}"
    end)
    |> Enum.join("\n")
  end
end
