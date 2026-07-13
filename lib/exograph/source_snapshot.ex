defmodule Exograph.SourceSnapshot do
  @moduledoc "Immutable, reproducible source input hydrated from an Exograph index."

  use JSONCodec

  alias Exograph.{File, PackageVersion}

  @type t :: %__MODULE__{
          package_version: PackageVersion.t(),
          files: [File.t()],
          fingerprint: String.t(),
          complete: boolean(),
          provenance: map()
        }

  @enforce_keys [:package_version, :files, :fingerprint, :complete, :provenance]
  defstruct [:package_version, :files, :fingerprint, :complete, :provenance]
end
