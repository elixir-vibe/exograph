defmodule Exograph.Storage.ReferenceRecord do
  @moduledoc false

  use Ecto.Schema

  alias Exograph.Reference

  @primary_key {:id, :id, autogenerate: true}
  @schema_prefix nil
  schema "exograph_references" do
    field(:package_id, :integer)
    field(:package_version_id, :integer)
    field(:file_id, :integer)
    field(:fragment_id, :integer)
    field(:kind, Ecto.Enum, values: [:local_call, :remote_call, :alias, :module_attribute])
    field(:module, :string)
    field(:name, :string)
    field(:arity, :integer)
    field(:qualified_name, :string)
    field(:line, :integer)
    field(:column, :integer)

    timestamps(type: :utc_datetime_usec)
  end

  @fields [
    :id,
    :package_id,
    :package_version_id,
    :file_id,
    :fragment_id,
    :kind,
    :module,
    :name,
    :arity,
    :qualified_name,
    :line,
    :column
  ]

  def from_reference(%Reference{} = reference), do: Map.take(reference, @fields -- [:id])

  def to_reference(%__MODULE__{} = record) do
    struct(Reference, Map.take(record, @fields))
  end
end
