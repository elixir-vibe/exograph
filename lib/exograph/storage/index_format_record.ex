defmodule Exograph.Storage.IndexFormatRecord do
  @moduledoc false

  use Ecto.Schema

  @primary_key {:id, :id, autogenerate: false}
  @schema_prefix nil
  schema "exograph_index_format" do
    field(:format_version, :integer)
    field(:parser_version, :integer)
  end
end
