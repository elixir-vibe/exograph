defmodule Exograph.Reach.SourceSmellAudit.Finding do
  @moduledoc "A Reach smell finding discovered in an Exograph fragment."

  @enforce_keys [:check, :kind, :message, :file, :line]
  defstruct [
    :check,
    :kind,
    :message,
    :package,
    :package_version,
    :file,
    :line,
    :snippet,
    :anchor_term
  ]

  @type t :: %__MODULE__{
          check: module(),
          kind: atom(),
          message: String.t(),
          package: String.t() | nil,
          package_version: String.t() | nil,
          file: String.t(),
          line: pos_integer() | non_neg_integer(),
          snippet: String.t() | nil,
          anchor_term: String.t() | nil
        }
end
