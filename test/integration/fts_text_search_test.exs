defmodule Exograph.Integration.FTSTextSearchTest do
  use ExUnit.Case, async: false

  @moduletag :fts

  setup_all do
    case System.get_env("QUACKDB_FTS_TEST_URI") do
      nil ->
        {:skip, "set QUACKDB_FTS_TEST_URI to run against a DuckDB server with the fts extension"}

      uri ->
        Application.ensure_all_started(:ecto_sql)
        Application.ensure_all_started(:quackdb)

        Application.put_env(:exograph, Exograph.DuckDBRepo,
          uri: uri,
          token: System.get_env("QUACKDB_FTS_TEST_TOKEN", ""),
          pool_size: 1,
          log: false
        )

        start_supervised!(Exograph.DuckDBRepo)
        :ok
    end
  end

  test "identifier BM25 prefilter preserves exact dotted and bang matches" do
    prefix = "fts_identifier_#{System.unique_integer([:positive])}"

    on_exit(fn -> Exograph.DuckDBSupport.drop_prefix(prefix) end)

    {:ok, index} =
      Exograph.index_sources(
        [
          {"lib/demo.ex", "defmodule Demo do\n  def run(id), do: Repo.get!(User, id)\nend"},
          {"lib/other.ex",
           "defmodule Other do\n  def run(id), do: Repo.insert(User.changeset(id))\nend"}
        ],
        Exograph.DuckDBSupport.opts(prefix, extractors: [:ex_ast], min_mass: 1)
      )

    :ok = Exograph.DuckDB.create_bm25_indexes!(repo: Exograph.DuckDBRepo, prefix: prefix)

    explanation = Exograph.explain_text(index, "Repo.get!")
    assert explanation.strategy == :bm25
    assert explanation.identifier_tokens == ["repo", "get"]

    assert {:ok, bm25_hits} = Exograph.search_text(index, "Repo.get!", limit: 10)

    assert {:ok, ilike_hits} =
             Exograph.search_text(index, "Repo.get!", limit: 10, force_ilike: true)

    assert Enum.map(bm25_hits, & &1.fragment.id) == Enum.map(ilike_hits, & &1.fragment.id)
  end
end
