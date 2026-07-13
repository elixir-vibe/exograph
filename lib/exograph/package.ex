defmodule Exograph.Package do
  @moduledoc """
  Source package identity for multi-package indexes.
  """

  use JSONCodec

  @type ecosystem :: String.t()

  @type t :: %__MODULE__{
          id: integer() | nil,
          ecosystem: ecosystem(),
          name: String.t(),
          metadata: map()
        }

  defstruct id: nil, ecosystem: "hex", name: nil, metadata: %{}

  @spec new(keyword() | map()) :: t()
  def new(attrs) do
    attrs = Map.new(attrs)
    ecosystem = attrs |> Map.get(:ecosystem, "hex") |> to_string()
    name = Map.fetch!(attrs, :name)

    %__MODULE__{
      id: Map.get(attrs, :id),
      ecosystem: ecosystem,
      name: name,
      metadata: Map.get(attrs, :metadata, %{})
    }
  end
end
