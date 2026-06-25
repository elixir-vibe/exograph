defmodule Exograph.Storage.FragmentTermRecord do
  @moduledoc """
  Ecto schema for fragment-to-term inverted-index rows.
  """

  use Ecto.Schema

  @primary_key false
  @schema_prefix nil
  schema "exograph_fragment_terms" do
    field(:term_id, :integer)
    field(:fragment_id, :integer)
  end
end
