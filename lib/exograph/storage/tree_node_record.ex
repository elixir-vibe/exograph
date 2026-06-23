defmodule Exograph.Storage.TreeNodeRecord do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset

  alias Exograph.Tree.Node

  @primary_key false
  @schema_prefix nil
  schema "exograph_tree_nodes" do
    field(:fragment_id, :integer, primary_key: true)
    field(:id, :integer, primary_key: true)
    field(:parent_id, :integer)
    field(:ordinal, :integer)
    field(:role, :string)
    field(:kind, :string)
    field(:label, :string)
    field(:line, :integer)
    field(:preorder, :integer)
    field(:postorder, :integer)
    field(:depth, :integer)
  end

  def changeset(record, attrs) do
    record
    |> cast(attrs, __schema__(:fields))
    |> validate_required([
      :fragment_id,
      :id,
      :ordinal,
      :kind,
      :line,
      :preorder,
      :postorder,
      :depth
    ])
  end

  def from_node(%Node{} = node) do
    %{
      fragment_id: node.fragment_id,
      id: node.id,
      parent_id: node.parent_id,
      ordinal: node.ordinal,
      role: stringify(node.role),
      kind: Atom.to_string(node.kind),
      label: node.label,
      line: node.line,
      preorder: node.preorder,
      postorder: node.postorder,
      depth: node.depth
    }
  end

  def to_node(%__MODULE__{} = record) do
    %Node{
      fragment_id: record.fragment_id,
      id: record.id,
      parent_id: record.parent_id,
      ordinal: record.ordinal,
      role: atomize(record.role),
      kind: atomize(record.kind),
      label: record.label,
      line: record.line,
      preorder: record.preorder,
      postorder: record.postorder,
      depth: record.depth
    }
  end

  defp stringify(nil), do: nil
  defp stringify(value) when is_atom(value), do: Atom.to_string(value)
  defp stringify(value), do: to_string(value)
  defp atomize(nil), do: nil
  defp atomize(value), do: String.to_existing_atom(value)
end
