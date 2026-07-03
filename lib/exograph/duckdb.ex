defmodule Exograph.DuckDB do
  @moduledoc """
  DuckDB schema helpers for QuackDB-backed Exograph storage.
  """

  import Ecto.Query

  alias Ecto.Migration.Runner
  alias Exograph.Storage.{Format, FragmentTermRecord, Schema}
  alias Exograph.Storage.Migrations.CreateSchema

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

    Format.ensure_current_or_empty!(repo, prefix)

    Application.put_env(:exograph, CreateSchema, prefix: prefix)

    Runner.run(
      repo,
      repo.config(),
      Format.current_schema_version(),
      CreateSchema,
      :forward,
      :up,
      :up,
      log: false,
      log_migrations_sql: false
    )

    record_current_schema_version!(repo, prefix)

    :ok
  end

  defp record_current_schema_version!(repo, prefix) do
    source = Schema.source(:schema_migrations, prefix)
    version = Format.current_schema_version()

    repo.insert_all(source, [%{version: version}],
      conflict_target: [:version],
      on_conflict: :nothing
    )

    unless version in applied_versions(repo, prefix) do
      repo.insert_all(source, [%{version: version}])
    end

    checkpoint(repo)
  end

  defp checkpoint(repo) do
    repo.query!("CHECKPOINT", [], timeout: :infinity)
    :ok
  rescue
    _ -> :ok
  end

  defp applied_versions(repo, prefix) do
    Schema.source(:schema_migrations, prefix)
    |> select([migration], migration.version)
    |> repo.all(timeout: 30_000)
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

  @doc "Ensures structural lookup tables are ready for term-based queries."
  def optimize_structural_indexes!(opts) do
    migrate!(opts)
    cluster_fragment_terms!(opts)
  end

  defp cluster_fragment_terms!(opts) do
    repo = Keyword.fetch!(opts, :repo)
    prefix = Keyword.get(opts, :prefix, "exograph")
    source = Schema.table_name(prefix, :fragment_terms)

    query =
      from(fragment_term in {source, FragmentTermRecord},
        order_by: [asc: fragment_term.term_id, asc: fragment_term.fragment_id],
        select: %{term_id: fragment_term.term_id, fragment_id: fragment_term.fragment_id}
      )

    repo.query!(QuackDB.DDL.create_table(source, as: query, or_replace: true), [],
      timeout: :infinity
    )

    :ok
  end

  defp create_fts_index!(repo, prefix, table, id_column, columns) do
    repo.query!(
      QuackDB.FTS.create_index(Schema.table_name(prefix, table), id_column, columns,
        overwrite: true
      ),
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
