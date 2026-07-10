defmodule Exograph.DuckDBTest do
  use ExUnit.Case, async: false

  import Ecto.Query

  alias Exograph.DuckDBSupport
  alias Exograph.Storage.Schema

  @moduletag :integration

  test "text search applies skip to matching files" do
    DuckDBSupport.start_managed_repo!()
    prefix = "exograph_duckdb_text_pagination_#{System.unique_integer([:positive])}"

    assert {:ok, index} =
             Exograph.index_sources(
               [
                 {"lib/alpha.ex",
                  "defmodule Alpha do\n  # pagination needle\n  def run, do: :ok\nend"},
                 {"lib/beta.ex",
                  "defmodule Beta do\n  # pagination needle\n  def run, do: :ok\nend"}
               ],
               DuckDBSupport.opts(prefix, extractors: [:ex_ast], min_mass: 1)
             )

    assert {:ok, [first]} = Exograph.search_text(index, "pagination needle", limit: 1)
    assert {:ok, [second]} = Exograph.search_text(index, "pagination needle", limit: 1, skip: 1)
    refute first.fragment.file == second.fragment.file
  end

  test "structural optimization preserves fragment term rows" do
    DuckDBSupport.start_managed_repo!()
    prefix = "exograph_duckdb_optimize_#{System.unique_integer([:positive])}"
    source = Schema.fragment_terms_source(prefix)

    Exograph.DuckDB.migrate!(repo: Exograph.DuckDBRepo, prefix: prefix)

    rows = [
      %{term_id: 3, fragment_id: 20},
      %{term_id: 1, fragment_id: 10},
      %{term_id: 2, fragment_id: 30},
      %{term_id: 1, fragment_id: 40}
    ]

    assert {4, nil} = Exograph.DuckDBRepo.insert_all(source, rows)

    assert :ok =
             Exograph.DuckDB.optimize_structural_indexes!(
               repo: Exograph.DuckDBRepo,
               prefix: prefix
             )

    expected_rows = Enum.sort_by(rows, &{&1.term_id, &1.fragment_id})

    assert ^expected_rows =
             from(fragment_term in source,
               order_by: [asc: fragment_term.term_id, asc: fragment_term.fragment_id],
               select: %{term_id: fragment_term.term_id, fragment_id: fragment_term.fragment_id}
             )
             |> Exograph.DuckDBRepo.all()
  end
end
