defmodule Exograph.Storage.GraphNodeRecord do
  @moduledoc """
  Ecto schema for call-graph nodes extracted from source code.
  """

  use Ecto.Schema

  alias Exograph.GraphNode

  @primary_key {:id, :id, autogenerate: true}
  @schema_prefix nil
  schema "exograph_graph_nodes" do
    field(:package_id, :integer)
    field(:package_version_id, :integer)
    field(:file_id, :integer)
    field(:fragment_id, :integer)
    field(:engine, :string)
    field(:external_id, :string)
    field(:kind, Ecto.Enum, values: [:function, :external_function])
    field(:module, :string)
    field(:name, :string)
    field(:arity, :integer)
    field(:qualified_name, :string)
    field(:line, :integer)
    field(:column, :integer)
    field(:metadata, :map)

    timestamps(type: :utc_datetime_usec)
  end

  @insert_fields [
    :package_id,
    :package_version_id,
    :file_id,
    :fragment_id,
    :engine,
    :external_id,
    :kind,
    :module,
    :name,
    :arity,
    :qualified_name,
    :line,
    :column,
    :metadata
  ]

  def from_graph_node(%GraphNode{} = node) do
    Map.take(node, @insert_fields)
  end

  def to_graph_node(%__MODULE__{} = record) do
    struct(GraphNode, Map.take(record, [:id | @insert_fields]))
  end
end
