defmodule Exograph.Hydration do
  @moduledoc false

  import Ecto.Query

  alias Exograph.{File, Index, PackageVersion, SourceSnapshot}
  alias Exograph.Storage.Schema

  def package_version(%Index{} = index, %PackageVersion{} = version, opts) do
    with {:ok, stored_version} <- resolve_version(index, version) do
      files = load_files(index, stored_version, opts)

      {:ok,
       %SourceSnapshot{
         package_version: stored_version,
         files: files,
         fingerprint: fingerprint(stored_version, files),
         complete: stored_version.metadata[:index_state] == "complete",
         provenance: %{
           index_prefix: index.inverted.prefix,
           package_version_id: stored_version.id,
           file_count: length(files)
         }
       }}
    end
  end

  defp resolve_version(index, version) do
    packages = Schema.packages_source(index.inverted.prefix)

    query =
      from(stored in Schema.package_versions_source(index.inverted.prefix),
        join: package in ^packages,
        on: package.id == stored.package_id,
        where:
          package.ecosystem == ^version.ecosystem and package.name == ^version.package_name and
            stored.version == ^version.version,
        limit: 1,
        select: {stored, package.ecosystem, package.name}
      )

    case index.inverted.repo.one(query) do
      {stored, ecosystem, package_name} ->
        {:ok,
         PackageVersion.new(%{
           id: stored.id,
           package_id: stored.package_id,
           ecosystem: ecosystem,
           name: package_name,
           version: stored.version,
           source_ref: stored.source_ref,
           checksum: stored.checksum,
           metadata: Map.put(stored.metadata || %{}, :index_state, stored.index_state)
         })}

      nil ->
        {:error, :package_version_not_found}
    end
  end

  defp load_files(index, version, opts) do
    include_ast? = Keyword.get(opts, :include_ast, false)
    paths = Keyword.get(opts, :paths, ["lib/**"])

    records =
      from(file in Schema.files_source(index.inverted.prefix),
        where: file.package_version_id == ^version.id,
        order_by: [asc: file.path],
        select: file
      )
      |> index.inverted.repo.all(timeout: :infinity)

    root = source_root(records)

    records
    |> Enum.map(&{&1, logical_path(&1.path, root)})
    |> Enum.filter(fn {_record, path} -> selected_path?(path, paths) end)
    |> Enum.map(fn {record, path} -> to_file(record, path, include_ast?) end)
  end

  defp to_file(record, path, include_ast?) do
    %File{
      id: record.id,
      package_id: record.package_id,
      package_version_id: record.package_version_id,
      path: path,
      source: record.source,
      ast: if(include_ast?, do: Exograph.AST.Codec.load(record.ast), else: nil),
      comments_text: record.comments_text,
      identifier_tokens: record.identifier_tokens,
      sha256: record.sha256
    }
  end

  defp source_root([]), do: nil

  defp source_root(records) do
    paths = Enum.map(records, & &1.path)

    if Enum.all?(paths, &(Path.type(&1) == :absolute)) do
      paths
      |> Enum.map(&(Path.dirname(&1) |> Path.split()))
      |> common_components()
      |> Path.join()
    end
  end

  defp common_components([components | rest]) do
    Enum.reduce(rest, components, fn current, common ->
      Enum.zip(common, current)
      |> Enum.take_while(fn {left, right} -> left == right end)
      |> Enum.map(&elem(&1, 0))
    end)
  end

  defp logical_path(path, nil), do: path
  defp logical_path(path, root), do: Path.relative_to(path, root)

  defp selected_path?(path, patterns), do: Enum.any?(patterns, &path_matches?(path, &1))

  defp path_matches?(path, pattern) do
    cond do
      String.ends_with?(pattern, "/**") ->
        String.starts_with?(path, String.trim_trailing(pattern, "**"))

      String.contains?(pattern, "*") ->
        expression =
          pattern
          |> Regex.escape()
          |> String.replace("\\*\\*", ".*")
          |> String.replace("\\*", "[^/]*")

        Regex.match?(Regex.compile!("^#{expression}$"), path)

      true ->
        path == pattern
    end
  end

  defp fingerprint(version, files) do
    payload =
      {version.ecosystem, version.package_name, version.version,
       Enum.map(files, &{&1.path, &1.sha256})}
      |> :erlang.term_to_binary()

    :crypto.hash(:sha256, payload) |> Base.encode16(case: :lower)
  end
end
