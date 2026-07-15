defmodule Exograph.Storage.Schema do
  @moduledoc """
  Declares Exograph storage tables, Ecto record modules, and index metadata.

  Callers use this module for prefixed table names and Ecto source tuples so the
  physical DuckDB schema has a single naming authority.
  """

  import Exograph.Storage.Schema.Declaration

  alias Exograph.Storage.{
    CallEdgeRecord,
    CommentRecord,
    DefinitionRecord,
    FileRecord,
    FragmentRecord,
    FragmentTermRecord,
    GraphNodeRecord,
    IndexFormatRecord,
    PackageRecord,
    PackageVersionRecord,
    ReferenceRecord,
    TermRecord
  }

  @tables [
    table(:index_format, IndexFormatRecord) do
      unique_index([:id], name: :singleton)
    end,
    table(:packages, PackageRecord) do
      unique_index([:ecosystem, :name], name: :ecosystem_name)
    end,
    table(:package_versions, PackageVersionRecord) do
      unique_index([:package_id, :version], name: :package_version)
    end,
    table(:files, FileRecord, primary_key: false) do
      unique_index([:package_version_id, :path], name: :package_version_path)
    end,
    table(:terms, TermRecord, primary_key: false) do
      unique_index([:term], name: :term)
    end,
    table(:fragment_terms, FragmentTermRecord, primary_key: false),
    table(:fragments, FragmentRecord, primary_key: false) do
      unique_index([:content_hash], name: :content_hash)
      index([:kind, :name, :arity], name: :kind_name_arity)
    end,
    table(:comments, CommentRecord, primary_key: false),
    table(:definitions, DefinitionRecord, primary_key: false),
    table(:references, ReferenceRecord, primary_key: false),
    table(:graph_nodes, GraphNodeRecord, primary_key: false),
    table(:call_edges, CallEdgeRecord, primary_key: false)
  ]

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

  def index_name(prefix, table, suffix), do: "#{prefix}_#{table}_#{to_string(suffix)}_idx"

  def index_format_source(prefix), do: source(:index_format, prefix)

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

  defp table!(name) do
    Enum.find(@tables, &(&1.name == name)) ||
      raise ArgumentError, "unknown storage table: #{name}"
  end
end
