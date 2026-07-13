defmodule Exograph.API.Error do
  @moduledoc "Machine-readable error details returned by Exograph's JSON API."

  use JSONCodec

  @enforce_keys [:code, :message]
  defstruct [:code, :message, details: %{}]

  @type t :: %__MODULE__{
          code: String.t(),
          message: String.t(),
          details: map()
        }
end
