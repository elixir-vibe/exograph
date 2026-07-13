defmodule Exograph.PatternAudit.Pattern do
  @moduledoc "A planned Reach source-pattern smell used by the Exograph audit scanner."

  @enforce_keys [:module, :source, :kind, :message, :prefilter, :pattern, :required_terms]
  defstruct [
    :id,
    :module,
    :source,
    :kind,
    :message,
    :prefilter,
    :pattern,
    :anchor_term,
    :anchor_id,
    :anchor_count,
    required_terms: MapSet.new(),
    required_term_ids: MapSet.new(),
    missing_terms: []
  ]

  @type t :: %__MODULE__{
          id: non_neg_integer() | nil,
          module: module(),
          source: :pattern | :query,
          kind: atom(),
          message: String.t(),
          prefilter: term(),
          pattern: ExAST.Pattern.pattern() | ExAST.CompiledPattern.t() | ExAST.Selector.t(),
          required_terms: MapSet.t(String.t()),
          required_term_ids: MapSet.t(integer()),
          missing_terms: [String.t()],
          anchor_term: String.t() | nil,
          anchor_id: integer() | nil,
          anchor_count: non_neg_integer() | :missing | nil
        }
end
