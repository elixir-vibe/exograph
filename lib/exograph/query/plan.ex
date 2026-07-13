defmodule Exograph.Query.Plan do
  @moduledoc "Public, storage-independent plan for an Exograph query."

  use JSONCodec

  alias Exograph.Query

  @enforce_keys [:query, :execution, :hydration, :required_terms]
  defstruct [:query, :execution, :hydration, required_terms: []]

  @type t :: %__MODULE__{
          query: Query.t(),
          execution: :indexed_structural | :relational,
          hydration: :indexed_fragments | :none,
          required_terms: [String.t()]
        }

  codec(:execution, atom: :existing)
  codec(:hydration, atom: :existing)
end
