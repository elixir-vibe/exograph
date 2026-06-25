defmodule Exograph.Storage.Config do
  @moduledoc """
  Normalizes storage options into store structs.

  This module owns option defaults and migration triggering so schema metadata stays
  focused on table declarations.
  """

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
      static_atoms: Keyword.get(opts, :static_atoms, :existing)
    }

    module
    |> struct()
    |> Map.from_struct()
    |> Map.keys()
    |> then(&Map.take(attrs, &1))
    |> then(&struct(module, &1))
  end

  def migrate(opts) do
    if Keyword.get(opts, :migrate?, false), do: DuckDB.migrate!(opts)
  end
end
