defmodule Exograph.PatternAudit.Finding do
  @moduledoc "A Reach smell finding discovered in an Exograph fragment."

  @enforce_keys [:check, :kind, :message, :file, :line]
  defstruct [
    :check,
    :kind,
    :message,
    :package,
    :package_version,
    :file,
    :file_id,
    :fragment_id,
    :line,
    :range,
    :match_fingerprint,
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
          file_id: integer() | nil,
          fragment_id: integer() | nil,
          line: pos_integer() | non_neg_integer(),
          range: map() | nil,
          match_fingerprint: String.t() | nil,
          snippet: String.t() | nil,
          anchor_term: String.t() | nil
        }
end
