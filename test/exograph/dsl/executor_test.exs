defmodule Exograph.DSL.ExecutorTest do
  use ExUnit.Case, async: false

  alias Exograph.DuckDBSupport
  alias Exograph.Web.SafeEval

  setup do
    endpoint = "quack:127.0.0.1:#{Mix.Exograph.DuckDBOptions.free_tcp_port!()}"
    database = DuckDBSupport.start_managed_repo!(endpoint: endpoint)
    prefix = "executor_semantics_#{System.unique_integer([:positive])}"

    on_exit(fn ->
      File.rm(database)
      File.rm(database <> ".wal")
    end)

    {:ok, index} =
      Exograph.index_sources(
        [
          {"lib/demo.ex",
           """
           defmodule Demo do
             def run(value) do
               Enum.map([value], & &1)
             end

             def other do
               # TODO: check later
               :ok
             end
           end
           """}
        ],
        DuckDBSupport.opts(prefix,
          extractors: [:ex_ast],
          min_mass: 1,
          package: %{name: "demo"},
          package_version: %{name: "demo", version: "1.0.0"}
        )
      )

    {:ok, index: index}
  end

  test "matches on Fragment is root-only", %{index: index} do
    query!(~s|from(f in Fragment, where: matches(f, "def _ do ... end"), limit: 20)|)
    |> then(&Exograph.all(index, &1, limit: 20))
    |> assert_ok_hits(fn hits ->
      assert Enum.map(hits, & &1.fragment.kind) == [:def, :def]
      assert Enum.map(hits, & &1.fragment.name) |> Enum.sort() == ["other", "run"]
    end)
  end

  test "contains filters descendants of the root-matched fragment", %{index: index} do
    query!(
      ~s|from(f in Fragment, where: matches(f, "def _ do ... end"), where: contains(f, "Enum.map(...)"), limit: 20)|
    )
    |> then(&Exograph.all(index, &1, limit: 20))
    |> assert_ok_hits(fn hits ->
      assert Enum.map(hits, & &1.fragment.name) == ["run"]
    end)
  end

  test "text contains filters against hydrated source", %{index: index} do
    query!(
      ~s|from(f in Fragment, where: matches(f, "def _ do ... end"), where: contains(f, "# TODO"), limit: 20)|
    )
    |> then(&Exograph.all(index, &1, limit: 20))
    |> assert_ok_hits(fn hits ->
      assert Enum.map(hits, & &1.fragment.name) == ["other"]
    end)
  end

  test "plain text contains token is not treated as an AST alias", %{index: index} do
    query =
      query!(
        ~s|from(f in Fragment, where: matches(f, "def _ do ... end"), where: contains(f, "TODO"), limit: 20)|
      )

    assert Exograph.DSL.Compiler.required_terms(query) == []

    index
    |> Exograph.all(query, limit: 20)
    |> assert_ok_hits(fn hits ->
      assert Enum.map(hits, & &1.fragment.name) == ["other"]
    end)
  end

  test "text contains handles empty candidate batches", %{index: index} do
    query =
      query!(
        ~s|from(f in Fragment, where: matches(f, "def _ do ... end"), where: contains(f, "definitely_absent_text"), limit: 20)|
      )

    assert {:ok, []} = Exograph.all(index, query, limit: 20)
  end

  test "missing structural terms return no candidates", %{index: index} do
    query =
      query!(~s|from(f in Fragment, where: contains(f, "def handle_event(_, _, _)"), limit: 20)|)

    assert {:ok, []} = Exograph.all(index, query, limit: 20)
  end

  test "missing required structural terms produce no candidates", %{index: index} do
    query =
      query!(
        ~s|from(f in Fragment, where: matches(f, "NeverIndexed.Module.call_987654321(_)"), limit: 20)|
      )

    assert {:ok, []} = Exograph.all(index, query, limit: 20)

    assert {:ok, %Exograph.Query.Estimate{value: 0, relation: :eq}} =
             Exograph.estimate_candidates(index, query)
  end

  test "named function patterns return only matching function fragments", %{index: index} do
    query!(~s|from(f in Fragment, where: matches(f, "def run(_) do ... end"), limit: 20)|)
    |> then(&Exograph.all(index, &1, limit: 20))
    |> assert_ok_hits(fn hits ->
      assert Enum.map(hits, & &1.fragment.kind) == [:def]
      assert Enum.map(hits, & &1.fragment.name) == ["run"]
      assert Enum.map(hits, & &1.fragment.arity) == [1]
    end)
  end

  test "explains structural candidate retrieval", %{index: index} do
    explanation = Exograph.explain(index, "def run(_) do ... end", limit: 5)

    assert "def.name:run" in explanation.logical.required_terms
    assert is_binary(explanation.physical.sql)
    assert %QuackDB.Profile{} = explanation.physical.analyze
    assert explanation.metrics.candidate_rows > 0
    assert explanation.metrics.hydrated_fragments > 0
    assert explanation.metrics.matches > 0
    assert is_number(explanation.metrics.total_ms)
  end

  test "fragment queries resume from a keyset cursor", %{index: index} do
    query = query!(~s|from(f in Fragment, where: matches(f, "def _ do ... end"), limit: 1)|)

    assert {:ok, [first]} = Exograph.all(index, query, limit: 1)

    cursor = {first.fragment.file_id, first.fragment.id}

    assert {:ok, [second]} = Exograph.all(index, query, limit: 1, cursor: cursor)
    assert second.fragment.id != first.fragment.id
  end

  test "counts named function patterns exactly", %{index: index} do
    query = query!(~s|from(f in Fragment, where: matches(f, "def run(_) do ... end"), limit: 1)|)

    assert {:ok, 1} = Exograph.count(index, query)
  end

  defp query!(source) do
    assert {:ok, query} = SafeEval.eval(source)
    query
  end

  defp assert_ok_hits(result, fun) do
    assert {:ok, hits} = result
    fun.(hits)
  end
end
