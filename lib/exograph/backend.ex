defmodule Exograph.Backend do
  @moduledoc false

  def inferred(opts) do
    case Keyword.get(opts, :repo) do
      nil -> :duckdb
      repo when is_atom(repo) -> inferred_repo(repo)
    end
  end

  def inferred_repo(repo) do
    cond do
      duckdb_repo?(repo) -> :duckdb
      postgres_repo?(repo) -> :postgres
      true -> :duckdb
    end
  end

  def duckdb_repo?(repo), do: adapter(repo) == Ecto.Adapters.QuackDB
  def postgres_repo?(repo), do: adapter(repo) == Ecto.Adapters.Postgres

  def adapter(repo), do: repo.__adapter__()
end
