defmodule Exograph.AST.LocatorTest do
  use ExUnit.Case, async: true

  alias Exograph.AST.Locator

  test "locates nodes from a precomputed index" do
    {:ok, ast} =
      Exograph.ElixirParser.string_to_quoted("""
      defmodule Demo.Locator do
        def one(value), do: value + 1
        def two(value), do: value + 2
      end
      """)

    target =
      ast
      |> Macro.prewalk(nil, fn
        {:def, _meta, [{name, _, _} | _]} = node, nil ->
          if Exograph.Ident.equal?(name, :two), do: {node, node}, else: {node, nil}

        node, acc ->
          {node, acc}
      end)
      |> elem(1)

    index = Locator.index(ast)

    assert Locator.locate(index, target) == Locator.locate(ast, target)
    assert {pre, post} = Locator.locate(index, target)
    assert is_integer(pre)
    assert is_integer(post)
  end
end
