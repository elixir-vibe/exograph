defmodule Exograph.API.PlanResponse do
  @moduledoc "Versioned JSON API response for logical query planning."

  use JSONCodec

  alias Exograph.Query.{Estimate, Plan}

  @enforce_keys [:plan, :estimate, :index]
  defstruct version: 1, plan: nil, estimate: nil, index: %{}

  @type t :: %__MODULE__{
          version: 1,
          plan: Plan.t(),
          estimate: Estimate.t(),
          index: map()
        }
end
