defmodule Exograph.Integration.DSLJoinExecutionTest do
  use ExUnit.Case, async: false

  alias Exograph.DSL.Executor.JoinBuilder
  alias Exograph.DSL.Planner
  alias Exograph.DuckDBSupport
  alias Exograph.Web.SafeEval

  setup do
    DuckDBSupport.start_managed_repo!()
    prefix = "dsl_join_execution_#{System.unique_integer([:positive])}"

    {:ok, index} =
      Exograph.index_sources(
        [
          {"lib/demo.ex",
           """
           defmodule Demo do
             def run(value) do
               Enum.map([value], & &1)
             end

             def other(value), do: String.trim(value)
           end
           """}
        ],
        DuckDBSupport.opts(prefix, extractors: [:ex_ast], min_mass: 1)
      )

    %{index: index}
  end

  test "builds a named-binding candidate query for multiple joins", %{index: index} do
    query =
      query!(
        ~s|from(f in Fragment, join: d in assoc(f, :definitions), join: r in assoc(f, :references), where: d.qualified_name == "Demo.run/1", where: r.qualified_name == "Enum.map/2")|
      )

    assert [%{fragment: fragment, first_join_id: definition_id, second_join_id: reference_id}] =
             index.inverted.repo.all(
               JoinBuilder.build(index, Planner.plan(query), candidate_limit: 10)
             )

    assert fragment.name == "run"
    assert is_integer(definition_id)
    assert is_integer(reference_id)
  end

  test "joins a function to only its contained reference", %{index: index} do
    query!(
      ~s|from(f in Fragment, join: r in assoc(f, :references), where: f.kind == :def, where: r.qualified_name == "Enum.map/2", select: {f, r})|
    )
    |> then(&Exograph.all(index, &1, limit: 10))
    |> then(fn {:ok, results} ->
      assert [{hit, reference}] = results
      assert hit.fragment.name == "run"
      assert reference.qualified_name == "Enum.map/2"
    end)
  end

  test "applies predicates for multiple fact joins in one function scope", %{index: index} do
    query!(
      ~s|from(f in Fragment, join: d in assoc(f, :definitions), join: r in assoc(f, :references), where: f.kind == :def, where: d.qualified_name == "Demo.run/1", where: r.qualified_name == "Enum.map/2", select: {f, d, r})|
    )
    |> then(&Exograph.all(index, &1, limit: 10))
    |> then(fn {:ok, results} ->
      assert [{hit, definition, reference}] = results
      assert hit.fragment.name == "run"
      assert definition.qualified_name == "Demo.run/1"
      assert reference.qualified_name == "Enum.map/2"
    end)
  end

  defp query!(source) do
    assert {:ok, query} = SafeEval.eval(source)
    query
  end
end
