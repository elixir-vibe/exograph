defmodule Exograph.Storage.FileRecord do
  @moduledoc false

  use Ecto.Schema

  alias Exograph.File

  @primary_key {:id, :id, autogenerate: true}
  schema "exograph_files" do
    field(:package_id, :integer)
    field(:package_version_id, :integer)
    field(:path, :string)
    field(:source, :string)
    field(:comments_text, :string)
    field(:sha256, :string)

    timestamps(type: :utc_datetime_usec)
  end

  def from_file(%File{} = file) do
    %{
      package_id: file.package_id,
      package_version_id: file.package_version_id,
      path: file.path,
      source: file.source,
      comments_text: file.comments_text,
      sha256: file.sha256
    }
  end
end
