defmodule Exograph.PatternAudit.Result do
  @moduledoc "Summary and findings returned by a Reach source smell audit scan."

  alias Exograph.PatternAudit.Finding

  defstruct findings: [],
            elapsed_ms: 0.0,
            candidate_count: 0,
            scanned_patterns: 0,
            skipped_patterns: []

  @type t :: %__MODULE__{
          findings: [Finding.t()],
          elapsed_ms: float(),
          candidate_count: non_neg_integer(),
          scanned_patterns: non_neg_integer(),
          skipped_patterns: [term()]
        }
end
