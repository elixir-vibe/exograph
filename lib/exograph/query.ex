defmodule Exograph.Query do
  @moduledoc """
  Stable logical query representation shared by the Elixir DSL, JSON API,
  planners, and consumers.

  Queries describe intent over public Exograph entities. Storage schemas,
  QuackDB repositories, and Ecto queries are physical implementation details.
  """

  use JSONCodec

  alias Exograph.Query.{Join, Predicate}

  @type source ::
          :package
          | :package_version
          | :file
          | :fragment
          | :definition
          | :reference
          | :call_edge

  @type select :: nil | String.t() | [String.t()]

  @type t :: %__MODULE__{
          version: pos_integer(),
          source:
            :package
            | :package_version
            | :file
            | :fragment
            | :definition
            | :reference
            | :call_edge,
          binding: String.t(),
          predicates: [Predicate.t()],
          joins: [Join.t()],
          select: select(),
          limit: pos_integer() | nil
        }

  @enforce_keys [:source, :binding]
  defstruct version: 1,
            source: nil,
            binding: nil,
            select: nil,
            limit: nil,
            predicates: [],
            joins: []

  codec(:source, atom: :existing)

  @doc "Validates the public query envelope version."
  def validate(%__MODULE__{version: 1} = query), do: {:ok, query}
  def validate(%__MODULE__{version: version}), do: {:error, {:unsupported_query_version, version}}

  @doc false
  def validate!(%__MODULE__{} = query) do
    case validate(query) do
      {:ok, query} ->
        query

      {:error, {:unsupported_query_version, version}} ->
        raise ArgumentError, "unsupported Exograph query version: #{inspect(version)}"
    end
  end

  @doc "Returns the versioned public query capabilities."
  def capabilities do
    %{
      version: 1,
      sources: [:package, :package_version, :file, :fragment, :definition, :reference, :call_edge],
      predicates: [:matches, :contains, :prefix_search, :eq, :cmp, :in],
      associations: %{
        fragment: [:definitions, :references, :calls],
        definition: [:calls]
      },
      hydration: [:package_version]
    }
  end
end
