defmodule Exograph.FileRef do
  @moduledoc "Lightweight identity for an indexed source file."

  use JSONCodec

  @type t :: %__MODULE__{
          id: integer(),
          package_id: integer() | nil,
          package_version_id: integer() | nil,
          path: String.t(),
          sha256: String.t() | nil
        }

  @enforce_keys [:id, :path]
  defstruct [:id, :package_id, :package_version_id, :path, :sha256]
end
