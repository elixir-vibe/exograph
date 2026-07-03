defmodule Exograph.Storage.TreeStore do
  @moduledoc """
  Query-time AST tree helper backed by file-level AST storage.
  """

  import Ecto.Query

  alias Exograph.DuckDB
  alias Exograph.Storage.{FragmentRecord, Hydration, Schema}
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
    query =
      from(fragment in {Schema.fragments_source(store.prefix), FragmentRecord},
        left_join: file in ^Schema.files_source(store.prefix),
        on: file.id == fragment.file_id,
        where: fragment.id == ^fragment_id,
        select: {fragment, file.source, file.path, file.ast}
      )

    case store.repo.one(query) do
      {%FragmentRecord{} = record, source, path, file_ast} ->
        record
        |> Hydration.fragment(source, path, nil, nil, file_ast)
        |> Tree.nodes()

      nil ->
        []
    end
  end
end
