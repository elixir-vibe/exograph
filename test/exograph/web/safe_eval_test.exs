defmodule Exograph.Web.SafeEvalTest do
  use ExUnit.Case, async: true

  alias Exograph.Web.SafeEval

  test "does not intern identifiers from web DSL queries" do
    binding = "query_binding_#{System.unique_integer([:positive])}"

    assert {:ok, query} =
             SafeEval.eval(
               ~s|from(#{binding} in Fragment, where: matches(#{binding}, "def _ do ... end"))|
             )

    assert query.binding == binding
    assert_raise ArgumentError, fn -> String.to_existing_atom(binding) end
  end
end
