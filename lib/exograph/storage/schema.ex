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
    PackageRecord,
    PackageVersionRecord,
    ReferenceRecord,
    TermRecord
  }

  @tables [
    table(:packages, PackageRecord) do
      unique_index([:ecosystem, :name], name: :ecosystem_name)
    end,
    table(:package_versions, PackageVersionRecord) do
      unique_index([:package_id, :version], name: :package_version)
    end,
    table(:files, FileRecord) do
      index([:package_version_id, :path], name: :package_path)
      unique_index([:package_version_id, :sha256], name: :package_version_sha256)
    end,
    table(:terms, TermRecord, primary_key: false) do
      unique_index([:term], name: :term)
    end,
    table(:fragment_terms, FragmentTermRecord, primary_key: false),
    table(:fragments, FragmentRecord) do
      unique_index([:content_hash], name: :content_hash)
      index([:package_id, :package_version_id], name: :package)
      index([:file_id], name: :file)
      index([:file_id, :line], name: :file_line)
      index([:file_id, :kind, :line], name: :file_kind_line)
      index([:kind, :name, :arity], name: :kind_name_arity)
    end,
    table(:comments, CommentRecord) do
      index([:file_id], name: :file)
      index([:fragment_id], name: :fragment)
    end,
    table(:definitions, DefinitionRecord) do
      index([:qualified_name], name: :qualified)
      index([:fragment_id], name: :fragment)
      index([:file_id, :line], name: :file_line)
    end,
    table(:references, ReferenceRecord) do
      index([:qualified_name], name: :qualified)
      index([:fragment_id], name: :fragment)
      index([:file_id, :line], name: :file_line)
    end,
    table(:graph_nodes, GraphNodeRecord) do
      index([:qualified_name], name: :qualified)
      index([:file_id], name: :file)
    end,
    table(:call_edges, CallEdgeRecord) do
      index([:caller_qualified_name], name: :caller)
      index([:callee_qualified_name], name: :callee)
      index([:file_id], name: :file)
    end
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
