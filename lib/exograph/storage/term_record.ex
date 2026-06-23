defmodule Exograph.Storage.TermRecord do
  @moduledoc false

  use Ecto.Schema

  @primary_key {:id, :id, autogenerate: true}
  @schema_prefix nil
  schema "exograph_terms" do
    field(:term, :string)
  end
end
