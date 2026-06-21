defmodule Exograph.Web.SearchResultTest do
  use ExUnit.Case, async: true

  alias Exograph.{Fragment, Hit}
  alias Exograph.Web.SearchResult

  test "structural fragment results display the matched definition instead of enclosing module" do
    ast =
      quote line: 10 do
        def run(value) do
          value
        end
      end

    hit = %Hit{
      fragment: %Fragment{
        file: "/tmp/sources/demo-1.0.0/lib/demo.ex",
        kind: :module,
        name: "Demo",
        module: "Demo",
        line: 1,
        source: "defmodule Demo do\n  def run(value), do: value\nend"
      },
      match: %{node: ast}
    }

    result = SearchResult.from(hit)

    assert result.kind == :def
    assert result.name == "run"
    assert result.arity == 1
    assert result.line == 10
    assert result.module == "Demo"
    assert result.package == "demo"
    assert result.package_version == "1.0.0"
  end

  test "internal unknown atom placeholders are hidden" do
    hit = %Hit{
      fragment: %Fragment{
        file: "/tmp/sources/demo-1.0.0/lib/demo.ex",
        kind: :module,
        name: "__exograph_unknown_atom__.__exograph_unknown_atom__",
        module: "__exograph_unknown_atom__",
        line: 1
      },
      match: nil
    }

    result = SearchResult.from(hit)

    assert result.name == nil
    assert result.module == nil
  end
end
