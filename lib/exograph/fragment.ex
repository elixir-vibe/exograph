defmodule Exograph.Fragment do
  @moduledoc """
  Searchable code unit.

  Fragments are the bridge between source parsing, structural terms, near-duplicate
  fingerprints, and the inverted index.
  """

  @type id :: integer()

  @type t :: %__MODULE__{
          id: integer() | nil,
          file: String.t(),
          source: String.t() | nil,
          package_id: integer() | nil,
          package_version_id: integer() | nil,
          package_version: String.t() | nil,
          file_id: integer() | nil,
          content_hash: binary() | nil,
          ast: Macro.t(),
          kind: atom(),
          module: String.t() | nil,
          name: String.t() | nil,
          arity: non_neg_integer() | nil,
          line: non_neg_integer(),
          end_line: non_neg_integer() | nil,
          mass: non_neg_integer(),
          exact_hash: binary() | nil,
          terms: MapSet.t(String.t()),
          sub_hashes: MapSet.t(integer())
        }

  defstruct id: nil,
            file: "",
            source: nil,
            package_id: nil,
            package_version_id: nil,
            package_version: nil,
            file_id: nil,
            content_hash: nil,
            ast: nil,
            kind: :unknown,
            module: nil,
            name: nil,
            arity: nil,
            line: 0,
            end_line: nil,
            mass: 0,
            exact_hash: nil,
            terms: MapSet.new(),
            sub_hashes: MapSet.new()
end
