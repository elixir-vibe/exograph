defmodule Exograph.PackageVersion do
  @moduledoc """
  Concrete package release/version identity for multi-version indexes.
  """

  use JSONCodec

  alias Exograph.Package

  @type t :: %__MODULE__{
          id: integer() | nil,
          package_id: integer() | nil,
          ecosystem: Package.ecosystem(),
          package_name: String.t(),
          version: String.t(),
          source_ref: String.t() | nil,
          checksum: String.t() | nil,
          metadata: map()
        }

  defstruct id: nil,
            package_id: nil,
            ecosystem: "hex",
            package_name: nil,
            version: nil,
            source_ref: nil,
            checksum: nil,
            metadata: %{}

  @spec new(keyword() | map()) :: t()
  def new(attrs) do
    attrs = Map.new(attrs)
    ecosystem = attrs |> Map.get(:ecosystem, "hex") |> to_string()
    package_name = Map.get(attrs, :package_name) || Map.fetch!(attrs, :name)
    package_id = Map.get(attrs, :package_id)
    version = Map.fetch!(attrs, :version)

    %__MODULE__{
      id: Map.get(attrs, :id),
      package_id: package_id,
      ecosystem: ecosystem,
      package_name: package_name,
      version: version,
      source_ref: Map.get(attrs, :source_ref),
      checksum: Map.get(attrs, :checksum),
      metadata: Map.get(attrs, :metadata, %{})
    }
  end
end
