defmodule Exograph.Web.HydrateRequest do
  @moduledoc false

  use JSONCodec, case: :camel

  @enforce_keys [:package_name, :version]
  defstruct [:package_name, :version, ecosystem: "hex", paths: ["lib/**"]]

  @type t :: %__MODULE__{
          package_name: String.t(),
          version: String.t(),
          ecosystem: String.t(),
          paths: [String.t()]
        }
end
