defmodule Exograph.Query.Estimate do
  @moduledoc "Bounded candidate estimate for a logical query plan."

  use JSONCodec

  @enforce_keys [:value, :relation]
  defstruct [:value, :relation]

  @type t :: %__MODULE__{value: non_neg_integer(), relation: :eq | :gte}

  codec(:relation, atom: :existing)
end
