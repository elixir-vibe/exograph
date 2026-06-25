defmodule Exograph.Storage.Scope do
  @moduledoc """
  Ecto predicates for applying package and package-version scopes to storage queries.
  """

  import Ecto.Query

  def where_scope(queryable, opts) do
    package_id = Keyword.get(opts, :package_id)
    package_version_id = Keyword.get(opts, :package_version_id)
    package_version = Keyword.get(opts, :package_version)

    queryable
    |> maybe_where_package(package_id)
    |> maybe_where_package_version(package_version_id || package_version)
  end

  defp maybe_where_package(queryable, nil), do: queryable

  defp maybe_where_package(queryable, package_id),
    do: where(queryable, [fragment], fragment.package_id == ^package_id)

  defp maybe_where_package_version(queryable, nil), do: queryable

  defp maybe_where_package_version(queryable, package_version_id),
    do: where(queryable, [fragment], fragment.package_version_id == ^package_version_id)
end
