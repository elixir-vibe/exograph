defmodule Exograph.Storage.Format do
  @moduledoc false

  import Ecto.Query

  alias Exograph.Storage.Schema

  @current_schema_version 2
  @current_parser_format :tagged_idents

  def current_schema_version, do: @current_schema_version
  def current_parser_format, do: @current_parser_format
  def current_manifest_version, do: @current_schema_version

  def ensure_current_or_empty!(repo, prefix) do
    case applied_versions(repo, prefix) do
      {:ok, []} -> :ok
      {:ok, versions} -> ensure_versions_current!(versions, prefix)
      {:error, :missing_schema_migrations} -> :ok
    end
  end

  def ensure_current!(repo, prefix) do
    case applied_versions(repo, prefix) do
      {:ok, versions} -> ensure_versions_current!(versions, prefix)
      {:error, :missing_schema_migrations} -> raise incompatible_index_error(prefix, [])
    end
  end

  defp ensure_versions_current!(versions, prefix) do
    if @current_schema_version in versions do
      :ok
    else
      raise incompatible_index_error(prefix, versions)
    end
  end

  defp applied_versions(repo, prefix) do
    versions =
      Schema.source(:schema_migrations, prefix)
      |> select([migration], migration.version)
      |> repo.all(timeout: 30_000)

    {:ok, versions}
  rescue
    _ -> {:error, :missing_schema_migrations}
  end

  defp incompatible_index_error(prefix, versions) do
    ArgumentError.exception(
      "refusing to open Exograph index prefix #{inspect(prefix)}: expected storage schema " <>
        "version #{@current_schema_version} (parser #{@current_parser_format}), got " <>
        inspect(Enum.sort(versions))
    )
  end
end
