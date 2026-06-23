defmodule Exograph.Storage.DefinitionRecord do
  @moduledoc false

  use Ecto.Schema

  alias Exograph.Definition

  @primary_key {:id, :id, autogenerate: true}
  @schema_prefix nil
  schema "exograph_definitions" do
    field(:package_id, :integer)
    field(:package_version_id, :integer)
    field(:file_id, :integer)
    field(:fragment_id, :integer)

    field(:kind, Ecto.Enum,
      values: [
        :module,
        :def,
        :defp,
        :defmacro,
        :defmacrop,
        :defdelegate,
        :defcallback,
        :defmacrocallback,
        :attribute
      ]
    )

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

  def from_definition(%Definition{} = definition), do: Map.take(definition, @fields -- [:id])

  def to_definition(%__MODULE__{} = record) do
    struct(Definition, Map.take(record, @fields))
  end
end
