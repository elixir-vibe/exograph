defmodule Exograph.DuckDB do
  @moduledoc """
  DuckDB schema helpers for QuackDB-backed Exograph storage.
  """

  alias Ecto.Migration.Runner
  alias Exograph.Storage.Ecto.Migrations.CreateSchema

  @doc "Configures DuckDB execution threads for the current connection."
  def configure_threads!(_repo, nil), do: :ok

  def configure_threads!(repo, threads) when is_integer(threads) and threads > 0 do
    repo.query!(QuackDB.SQL.set(:threads, threads), [], timeout: :infinity)
    :ok
  end

  @doc "Creates the Exograph DuckDB schema for a prefix."
  def migrate!(opts) do
    repo = Keyword.fetch!(opts, :repo)
    prefix = Keyword.get(opts, :prefix, "exograph")

    Application.put_env(:exograph, CreateSchema, prefix: prefix)

    Runner.run(repo, repo.config(), 1, CreateSchema, :forward, :up, :up,
      log: false,
      log_migrations_sql: false
    )

    repo.insert_all(
      {"#{prefix}_schema_migrations", Exograph.Storage.Ecto.SchemaMigration},
      [%{version: 1}],
      conflict_target: [:version],
      on_conflict: :nothing
    )

    :ok
  end

  @doc "Creates DuckDB FTS/BM25 indexes for searchable Exograph tables."
  def create_bm25_indexes!(opts) do
    repo = Keyword.fetch!(opts, :repo)
    prefix = Keyword.get(opts, :prefix, "exograph")

    execute_optional!(repo, QuackDB.FTS.install())
    execute_optional!(repo, QuackDB.FTS.load())

    create_fts_index!(repo, prefix, "files", :id, [:source, :comments_text])
    create_fts_index!(repo, prefix, "fragments", :id, [:name, :module, :kind])
    create_fts_index!(repo, prefix, "comments", :id, [:text])
    create_fts_index!(repo, prefix, "definitions", :id, [:name, :module, :qualified_name, :kind])
    create_fts_index!(repo, prefix, "references", :id, [:name, :module, :qualified_name, :kind])

    optimize_structural_indexes!(repo: repo, prefix: prefix)

    :ok
  end

  @doc "Sorts DuckDB structural inverted tables for zonemap-friendly term lookups."
  def optimize_structural_indexes!(opts) do
    repo = Keyword.fetch!(opts, :repo)
    prefix = Keyword.get(opts, :prefix, "exograph")
    table = "#{prefix}_fragment_terms"

    fragments_table = "#{prefix}_fragments"

    repo.query!(
      ~s|
      CREATE OR REPLACE TABLE "#{table}" AS
      SELECT DISTINCT unnest(terms) AS term_id, id AS fragment_id
      FROM "#{fragments_table}"
      ORDER BY term_id, fragment_id
      |,
      [],
      timeout: :infinity
    )

    :ok
  end

  defp create_fts_index!(repo, prefix, table, id_column, columns) do
    repo.query!(
      QuackDB.FTS.create_index("#{prefix}_#{table}", id_column, columns, overwrite: true),
      []
    )
  end

  defp execute_optional!(repo, statement) do
    repo.query!(statement, [])
    :ok
  rescue
    QuackDB.Error -> :ok
  end
end
