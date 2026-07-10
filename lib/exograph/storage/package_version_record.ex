defmodule Exograph.Storage.PackageVersionRecord do
  @moduledoc """
  Ecto schema for indexed package versions.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Exograph.PackageVersion

  @primary_key {:id, :id, autogenerate: true}
  @schema_prefix nil
  schema "exograph_package_versions" do
    field(:package_id, :integer)
    field(:version, :string)
    field(:source_ref, :string)
    field(:checksum, :string)
    field(:index_state, :string, default: "pending")
    field(:metadata, :map, default: %{})

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(record, attrs) do
    record
    |> cast(attrs, [:package_id, :version, :source_ref, :checksum, :index_state, :metadata])
    |> validate_required([:package_id, :version])
  end

  def from_package_version(%PackageVersion{} = version) do
    %{
      package_id: version.package_id,
      version: version.version,
      source_ref: version.source_ref,
      checksum: version.checksum,
      metadata: version.metadata
    }
  end
end
