defmodule Exograph.Extractor.ExASTTest do
  use ExUnit.Case, async: true

  alias Exograph.Extractor.ExAST

  test "carries file AST once per source file" do
    source = """
    defmodule Demo.Memory do
      def one(value), do: Enum.map(value, & &1)
      def two(value), do: Enum.filter(value, & &1)
      def three(value), do: Enum.reject(value, &is_nil/1)
    end
    """

    fragments = ExAST.index_source("lib/demo/memory.ex", source, min_mass: 1)

    assert length(fragments) > 1
    assert 1 == fragments |> Enum.count(& &1.file_ast)
    assert Enum.all?(fragments, & &1.node_pre)
    assert Enum.all?(fragments, & &1.node_post)
  end
end
