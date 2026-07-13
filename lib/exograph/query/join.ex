defmodule Exograph.Query.Join do
  @moduledoc "A serializable association join in the public Exograph query model."

  use JSONCodec

  @enforce_keys [:parent, :binding, :association]
  defstruct [:parent, :binding, :association]

  @type t :: %__MODULE__{
          parent: String.t(),
          binding: String.t(),
          association: atom()
        }

  codec(:association, atom: :existing)
end
