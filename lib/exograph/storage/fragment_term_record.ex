defmodule Exograph.Storage.FragmentTermRecord do
  @moduledoc false

  use Ecto.Schema

  @primary_key false
  @schema_prefix nil
  schema "exograph_fragment_terms" do
    field(:term_id, :integer)
    field(:fragment_id, :integer)
  end
end
