defmodule Exograph.Storage.Ecto.Options do
  @moduledoc false

  alias Exograph.{Package, PackageVersion, Postgres}

  def repo(opts), do: Postgres.fetch_repo!(opts)

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
      postgres_copy?: Keyword.get(opts, :postgres_copy?, false),
      defer_fragment_terms?: Keyword.get(opts, :defer_fragment_terms?, false),
      duckdb_insert_buffer: Keyword.get(opts, :duckdb_insert_buffer),
      duckdb_fragment_append: Keyword.get(opts, :duckdb_fragment_append, :ecto),
      static_atoms: Keyword.get(opts, :static_atoms, :existing)
    }

    module
    |> struct()
    |> Map.from_struct()
    |> Map.keys()
    |> then(&Map.take(attrs, &1))
    |> then(&struct(module, &1))
  end

  def hydrate_fragment(record, source, path) do
    record
    |> Map.put(:source, source)
    |> Map.put(:file, path)
    |> Exograph.Storage.Ecto.FragmentRecord.to_fragment()
  end

  def files_source(prefix), do: {"#{prefix}_files", Exograph.Storage.Ecto.FileRecord}
  def fragments_source(prefix), do: "#{prefix}_fragments"
  def comments_source(prefix), do: {"#{prefix}_comments", Exograph.Storage.Ecto.CommentRecord}

  def definitions_source(prefix),
    do: {"#{prefix}_definitions", Exograph.Storage.Ecto.DefinitionRecord}

  def references_source(prefix),
    do: {"#{prefix}_references", Exograph.Storage.Ecto.ReferenceRecord}

  def graph_nodes_source(prefix),
    do: {"#{prefix}_graph_nodes", Exograph.Storage.Ecto.GraphNodeRecord}

  def call_edges_source(prefix),
    do: {"#{prefix}_call_edges", Exograph.Storage.Ecto.CallEdgeRecord}

  def terms_source(prefix), do: {"#{prefix}_terms", Exograph.Storage.Ecto.TermRecord}

  def fragment_terms_source(prefix),
    do: {"#{prefix}_fragment_terms", Exograph.Storage.Ecto.FragmentTermRecord}

  def migrate(opts) do
    if Keyword.get(opts, :migrate?, false), do: Postgres.migrate!(opts)
  end
end
