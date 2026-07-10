defmodule Exograph.Hex.IndexReport do
  @moduledoc false

  use JSONCodec

  defmodule Failure do
    @moduledoc false

    use JSONCodec

    defstruct [:name, :version, :reason]

    @type t :: %__MODULE__{
            name: String.t() | nil,
            version: String.t() | nil,
            reason: String.t()
          }
  end

  defmodule Result do
    @moduledoc false

    defstruct ok: 0, skipped: 0, error: 0, failures: []
  end

  defstruct generated_at: nil,
            elapsed_ms: 0,
            ok: 0,
            skipped: 0,
            error: 0,
            failures: [],
            options: %{}

  @type t :: %__MODULE__{
          generated_at: String.t() | nil,
          elapsed_ms: non_neg_integer(),
          ok: non_neg_integer(),
          skipped: non_neg_integer(),
          error: non_neg_integer(),
          failures: [Failure.t()],
          options: map()
        }
end
