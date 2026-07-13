defmodule Exograph.DuckDB do
  @moduledoc """
  DuckDB schema helpers for QuackDB-backed Exograph storage.
  """

  import Ecto.Query

  alias Ecto.Migration.Runner
  alias Exograph.Storage.{FragmentTermRecord, IndexFormat, Schema}
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

    reject_legacy_index!(repo, prefix)
    Application.put_env(:exograph, CreateSchema, prefix: prefix)

    Runner.run(
      repo,
      repo.config(),
      0,
      CreateSchema,
      :forward,
      :up,
      :up,
      log: false,
      log_migrations_sql: false
    )

    IndexFormat.write_current!(repo, prefix)
    checkpoint(repo)
  end

  defp reject_legacy_index!(repo, prefix) do
    format_table = Schema.table_name(prefix, :index_format)
    fragments_table = Schema.table_name(prefix, :fragments)

    table_names = QuackDB.Meta.tables!(repo) |> Enum.map(& &1.name)

    cond do
      fragments_table in table_names and format_table not in table_names ->
        raise ArgumentError,
              "legacy Exograph index detected; rebuild it instead of migrating in place"

      fragments_table in table_names ->
        IndexFormat.ensure_compatible!(repo, prefix)

      true ->
        :ok
    end
  end

  defp checkpoint(repo) do
    QuackDB.Storage.checkpoint!(repo, timeout: :infinity)
    :ok
  rescue
    QuackDB.Error -> :ok
  end

  @doc "Creates DuckDB FTS/BM25 indexes for searchable Exograph tables."
  def create_bm25_indexes!(opts) do
    repo = Keyword.fetch!(opts, :repo)
    prefix = Keyword.get(opts, :prefix, "exograph")

    execute_optional!(repo, QuackDB.FTS.install())
    execute_optional!(repo, QuackDB.FTS.load())

    create_fts_index!(repo, prefix, "files", :id, [:source, :comments_text, :identifier_tokens],
      stemmer: :none,
      stopwords: :none
    )

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

  defp create_fts_index!(repo, prefix, table, id_column, columns, options \\ []) do
    repo.query!(
      QuackDB.FTS.create_index(
        Schema.table_name(prefix, table),
        id_column,
        columns,
        Keyword.put(options, :overwrite, true)
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
