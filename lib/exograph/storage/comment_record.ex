defmodule Exograph.Storage.CommentRecord do
  @moduledoc false

  use Ecto.Schema

  alias Exograph.Comment

  @primary_key {:id, :id, autogenerate: true}
  @schema_prefix nil
  schema "exograph_comments" do
    field(:package_id, :integer)
    field(:package_version_id, :integer)
    field(:file_id, :integer)
    field(:fragment_id, :integer)
    field(:text, :string)
    field(:line, :integer)
    field(:column, :integer)

    timestamps(type: :utc_datetime_usec)
  end

  def from_comment(%Comment{} = comment) do
    Map.take(comment, [
      :package_id,
      :package_version_id,
      :file_id,
      :fragment_id,
      :text,
      :line,
      :column
    ])
  end
end
