defmodule Exograph.DSL.Plan do
  @moduledoc false

  @type join :: Exograph.DSL.Plan.Join.t()

  @type t :: %__MODULE__{
          query: Exograph.Query.t(),
          source: Exograph.Query.source(),
          binding: String.t(),
          joins: [join()],
          predicates_by_binding: %{String.t() => [Exograph.Query.predicate()]},
          structural_predicates: [Exograph.Query.predicate()],
          select: Exograph.Query.select()
        }

  defstruct [
    :query,
    :source,
    :binding,
    :select,
    joins: [],
    predicates_by_binding: %{},
    structural_predicates: []
  ]
end
