defmodule Exograph.Similarity do
  @moduledoc false

  alias ExDNA.AST.{EditDistance, Fingerprint, Normalizer}
  alias Exograph.Storage.Ecto.FragmentStore
  alias Exograph.Index

  @default_opts [min_mass: 8, min_similarity: 0.8, limit: 20]

  @spec search(Index.t(), String.t() | Macro.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def search(%Index{} = index, source_or_ast, opts \\ []) do
    opts = Keyword.merge(@default_opts, opts)

    with {:ok, query_fragment} <- query_fragment(source_or_ast, opts) do
      fragments = FragmentStore.all(index.fragment_store)
      query_norm = Normalizer.normalize(query_fragment.ast)

      results =
        fragments
        |> Enum.filter(&mass_compatible?(&1, query_fragment))
        |> Enum.map(fn fragment ->
          overlap = subhash_overlap(fragment, query_fragment)
          similarity = EditDistance.similarity(query_norm, Normalizer.normalize(fragment.ast))

          %{
            fragment: fragment,
            score: similarity,
            similarity: similarity,
            subhash_overlap: overlap
          }
        end)
        |> Enum.filter(&(&1.similarity >= opts[:min_similarity]))
        |> Enum.sort_by(&{&1.similarity, &1.subhash_overlap}, :desc)
        |> Enum.take(opts[:limit])

      {:ok, results}
    end
  end

  defp query_fragment(source, opts) when is_binary(source) do
    with {:ok, ast} <- Code.string_to_quoted(source, line: 1, columns: true) do
      query_fragment(ast, opts)
    end
  end

  defp query_fragment(ast, opts) do
    fragments =
      Fingerprint.fragments(ast, "<query>", opts[:min_mass],
        literal_mode: :keep,
        normalize_pipes: true
      )

    case Enum.sort_by(fragments, & &1.mass, :desc) do
      [fragment | _] -> {:ok, fragment}
      [] -> {:error, :query_too_small}
    end
  end

  defp mass_compatible?(fragment, query_fragment) do
    min(fragment.mass, query_fragment.mass) / max(fragment.mass, query_fragment.mass) >= 0.5
  end

  defp subhash_overlap(fragment, query_fragment) do
    fragment.sub_hashes
    |> MapSet.intersection(query_fragment.sub_hashes)
    |> MapSet.size()
  end
end
