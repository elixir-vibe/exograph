defmodule Exograph.Storage.CallEdgeRecord do
  @moduledoc """
  Ecto schema for persisted call graph edges.
  """

  use Ecto.Schema

  alias Exograph.CallEdge

  @primary_key {:id, :id, autogenerate: true}
  @schema_prefix nil
  schema "exograph_call_edges" do
    field(:package_id, :integer)
    field(:package_version_id, :integer)
    field(:file_id, :integer)
    field(:caller_node_id, :integer)
    field(:callee_node_id, :integer)
    field(:call_site_fragment_id, :integer)
    field(:caller_qualified_name, :string)
    field(:callee_qualified_name, :string)
    field(:line, :integer)
    field(:column, :integer)
    field(:metadata, :map)

    timestamps(type: :utc_datetime_usec)
  end

  @fields [
    :id,
    :package_id,
    :package_version_id,
    :file_id,
    :caller_node_id,
    :callee_node_id,
    :call_site_fragment_id,
    :caller_qualified_name,
    :callee_qualified_name,
    :line,
    :column,
    :metadata
  ]

  def from_call_edge(%CallEdge{} = edge), do: Map.take(edge, @fields -- [:id])

  def to_call_edge(%__MODULE__{} = record) do
    struct(CallEdge, Map.take(record, @fields))
  end
end
