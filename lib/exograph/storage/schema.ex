defmodule Exograph.Storage.Schema do
  @moduledoc false

  alias Exograph.{DuckDB, Package, PackageVersion}

  import Exograph.Storage.Schema.DSL

  alias Exograph.Storage.{
    CallEdgeRecord,
    CommentRecord,
    DefinitionRecord,
    FileRecord,
    FragmentRecord,
    FragmentTermRecord,
    GraphNodeRecord,
    PackageRecord,
    PackageVersionRecord,
    ReferenceRecord,
    SchemaMigration,
    TermRecord,
    TreeNodeRecord
  }

  @tables [
    table(:schema_migrations, SchemaMigration, primary_key: false),
    table(:packages, PackageRecord),
    table(:package_versions, PackageVersionRecord),
    table(:files, FileRecord),
    table(:terms, TermRecord, primary_key: false),
    table(:fragment_terms, FragmentTermRecord, primary_key: false),
    table(:fragments, FragmentRecord),
    table(:comments, CommentRecord),
    table(:definitions, DefinitionRecord),
    table(:references, ReferenceRecord),
    table(:graph_nodes, GraphNodeRecord),
    table(:call_edges, CallEdgeRecord),
    table(:tree_nodes, TreeNodeRecord, primary_key: false)
  ]

  def repo(opts), do: Keyword.fetch!(opts, :repo)

  def prefix(opts), do: Keyword.get(opts, :prefix, "exograph")

  def package(opts) do
    case Keyword.get(opts, :package) do
      nil -> nil
      %Package{} = package -> package
      attrs -> Package.new(attrs)
    end
  end

  def extractors(opts), do: Keyword.get(opts, :extractors, [:ex_ast, :reach])

  def package_version(opts) do
    case Keyword.get(opts, :package_version) do
      nil -> nil
      %PackageVersion{} = version -> version
      attrs -> PackageVersion.new(attrs)
    end
  end

  def store(module, opts) do
    migrate(opts)

    attrs = %{
      repo: repo(opts),
      prefix: prefix(opts),
      package: package(opts),
      package_version: package_version(opts),
      extractors: extractors(opts),
      bm25?: Keyword.get(opts, :bm25?, true),
      defer_fragment_terms?: Keyword.get(opts, :defer_fragment_terms?, false),
      duckdb_insert_buffer: Keyword.get(opts, :duckdb_insert_buffer),
      duckdb_build_mode: Keyword.get(opts, :duckdb_build_mode, :online),
      duckdb_fragment_append: Keyword.get(opts, :duckdb_fragment_append, :merge),
      duckdb_fragment_payload_metrics?:
        Keyword.get(opts, :duckdb_fragment_payload_metrics?, false),
      static_atoms: Keyword.get(opts, :static_atoms, :existing)
    }

    module
    |> struct()
    |> Map.from_struct()
    |> Map.keys()
    |> then(&Map.take(attrs, &1))
    |> then(&struct(module, &1))
  end

  def hydrate_fragment(record, source, path, package_version \\ nil) do
    record
    |> Map.put(:source, source)
    |> Map.put(:file, path)
    |> Map.put(:package_version, package_version)
    |> Exograph.Storage.FragmentRecord.to_fragment()
  end

  def tables, do: @tables

  def table(table), do: table!(table)

  def source(table, prefix) do
    table = table!(table)
    {table_name(prefix, table.name), table.record}
  end

  def table_name(prefix, table) when is_atom(table) do
    "#{prefix}_#{table!(table).name}"
  end

  def table_name(prefix, suffix) when is_binary(suffix), do: "#{prefix}_#{suffix}"

  def index_name(prefix, table, suffix) when is_atom(table),
    do: index_name(prefix, Atom.to_string(table!(table).name), suffix)

  def index_name(prefix, table, suffix), do: "#{prefix}_#{table}_#{suffix}_idx"

  def packages_source(prefix), do: source(:packages, prefix)

  def files_source(prefix), do: source(:files, prefix)

  def package_versions_source(prefix), do: source(:package_versions, prefix)

  def fragments_source(prefix), do: table_name(prefix, :fragments)

  def comments_source(prefix), do: source(:comments, prefix)

  def definitions_source(prefix), do: source(:definitions, prefix)

  def references_source(prefix), do: source(:references, prefix)

  def graph_nodes_source(prefix), do: source(:graph_nodes, prefix)

  def call_edges_source(prefix), do: source(:call_edges, prefix)

  def terms_source(prefix), do: source(:terms, prefix)

  def fragment_terms_source(prefix), do: source(:fragment_terms, prefix)

  def migrate(opts) do
    if Keyword.get(opts, :migrate?, false), do: DuckDB.migrate!(opts)
  end

  defp table!(name) do
    Enum.find(@tables, &(&1.name == name)) ||
      raise ArgumentError, "unknown storage table: #{name}"
  end
end
