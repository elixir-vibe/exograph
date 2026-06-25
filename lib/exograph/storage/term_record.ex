defmodule Exograph.Storage.TermRecord do
  @moduledoc """
  Ecto schema for normalized structural search terms.
  """

  use Ecto.Schema

  @primary_key {:id, :id, autogenerate: true}
  @schema_prefix nil
  schema "exograph_terms" do
    field(:term, :string)
  end
end
