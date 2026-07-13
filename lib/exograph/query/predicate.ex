defmodule Exograph.Query.Predicate do
  @moduledoc "A serializable predicate in the public Exograph query model."

  use JSONCodec

  defstruct [:op, :binding, :field, :value, :comparison]

  @type op :: :matches | :contains | :prefix_search | :eq | :cmp | :in

  @type t :: %__MODULE__{
          op: :matches | :contains | :prefix_search | :eq | :cmp | :in,
          binding: String.t(),
          field: atom() | nil,
          value: term(),
          comparison: :> | :< | :>= | :<= | nil
        }

  codec(:op, atom: :existing)
  codec(:field, atom: :existing)
  codec(:comparison, atom: :existing)

  @doc false
  def to_internal(%__MODULE__{op: op, binding: binding, value: value})
      when op in [:matches, :contains],
      do: {op, binding, value}

  def to_internal(%__MODULE__{op: :cmp} = predicate),
    do: {:cmp, predicate.binding, predicate.field, predicate.comparison, predicate.value}

  def to_internal(%__MODULE__{} = predicate),
    do: {predicate.op, predicate.binding, predicate.field, predicate.value}
end
