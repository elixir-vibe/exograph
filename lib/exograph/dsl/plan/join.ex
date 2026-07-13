defmodule Exograph.DSL.Plan.Join do
  @moduledoc false

  @type t :: %__MODULE__{
          parent: String.t(),
          binding: String.t(),
          assoc: atom(),
          source: Exograph.Query.source(),
          position: pos_integer()
        }

  defstruct [:parent, :binding, :assoc, :source, :position]
end
