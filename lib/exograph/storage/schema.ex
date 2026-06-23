defmodule Exograph.Storage.Schema do
  @moduledoc false

  alias Exograph.{DuckDB, Package, PackageVersion}

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

  def files_source(prefix), do: {"#{prefix}_files", Exograph.Storage.FileRecord}

  def package_versions_source(prefix),
    do: {"#{prefix}_package_versions", Exograph.Storage.PackageVersionRecord}

  def fragments_source(prefix), do: "#{prefix}_fragments"
  def comments_source(prefix), do: {"#{prefix}_comments", Exograph.Storage.CommentRecord}

  def definitions_source(prefix),
    do: {"#{prefix}_definitions", Exograph.Storage.DefinitionRecord}

  def references_source(prefix),
    do: {"#{prefix}_references", Exograph.Storage.ReferenceRecord}

  def graph_nodes_source(prefix),
    do: {"#{prefix}_graph_nodes", Exograph.Storage.GraphNodeRecord}

  def call_edges_source(prefix),
    do: {"#{prefix}_call_edges", Exograph.Storage.CallEdgeRecord}

  def terms_source(prefix), do: {"#{prefix}_terms", Exograph.Storage.TermRecord}

  def fragment_terms_source(prefix),
    do: {"#{prefix}_fragment_terms", Exograph.Storage.FragmentTermRecord}

  def migrate(opts) do
    if Keyword.get(opts, :migrate?, false), do: DuckDB.migrate!(opts)
  end
end
