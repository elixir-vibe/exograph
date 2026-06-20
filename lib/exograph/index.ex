defmodule Exograph.Index do
  @moduledoc """
  Runtime handle for an Exograph index.

  The handle keeps candidate retrieval, fragment storage, and tree
  access state together for query execution.
  """

  @type t :: %__MODULE__{
          inverted: term(),
          fragment_store: term(),
          tree_store: term() | nil
        }

  defstruct inverted: nil,
            fragment_store: nil,
            tree_store: nil
end
