defmodule Exograph.API.ErrorResponse do
  @moduledoc "Versioned JSON API error envelope."

  use JSONCodec

  alias Exograph.API.Error

  @enforce_keys [:error]
  defstruct version: 1, error: nil

  @type t :: %__MODULE__{version: 1, error: Error.t()}

  @spec new(String.t(), String.t(), map()) :: t()
  def new(code, message, details \\ %{}) do
    %__MODULE__{error: %Error{code: code, message: message, details: details}}
  end
end
