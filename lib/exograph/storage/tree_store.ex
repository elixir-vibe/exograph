defmodule Exograph.Storage.TreeStore do
  @moduledoc """
  Durable AST tree node store backed by Ecto repositories.
  """

  alias Exograph.DuckDB
  alias Exograph.Storage.{FragmentRecord, Options}
  alias Exograph.Tree

  defstruct repo: nil, prefix: "exograph"

  @type t :: %__MODULE__{repo: module(), prefix: String.t()}

  def new(opts \\ []) do
    if Keyword.get(opts, :migrate?, false), do: DuckDB.migrate!(opts)

    {:ok,
     %__MODULE__{
       repo: Keyword.fetch!(opts, :repo),
       prefix: Keyword.get(opts, :prefix, "exograph")
     }}
  end

  def put_fragments(%__MODULE__{} = store, fragments) when is_list(fragments), do: {:ok, store}

  def nodes(%__MODULE__{} = store, fragment_id) do
    case store.repo.get({Options.fragments_source(store.prefix), FragmentRecord}, fragment_id) do
      %FragmentRecord{} = record ->
        record
        |> FragmentRecord.to_fragment()
        |> Tree.nodes()

      nil ->
        []
    end
  end
end
