defmodule Exograph.Storage.SchemaMigration do
  @moduledoc """
  Schema record used to mark Exograph DuckDB migrations applied.
  """

  use Ecto.Schema

  @primary_key {:version, :integer, autogenerate: false}
  schema "schema_migrations" do
  end
end
