defmodule Exograph.Similarity do
  @moduledoc false

  import Ecto.Query
  import QuackDB.Ecto.List, only: [has_any: 2]

  alias ExDNA.AST.{EditDistance, Fingerprint, Normalizer}
  alias Exograph.Index
  alias Exograph.Storage.{FragmentRecord, FragmentStore, Hydration, Schema}

  @default_opts [
    min_mass: 8,
    min_similarity: 0.8,
    limit: 20,
    prefilter: :auto,
    prefilter_min_similarity: 0.8
  ]

  @spec search(Index.t(), String.t() | Macro.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def search(%Index{} = index, source_or_ast, opts \\ []) do
    with {:ok, results, _diagnostics} <- run(index, source_or_ast, opts), do: {:ok, results}
  end

  @spec explain(Index.t(), String.t() | Macro.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def explain(%Index{} = index, source_or_ast, opts \\ []) do
    {elapsed_us, result} = :timer.tc(fn -> run(index, source_or_ast, opts) end)

    case result do
      {:ok, results, diagnostics} ->
        {:ok,
         Map.merge(diagnostics, %{
           returned_results: length(results),
           elapsed_ms: Float.round(elapsed_us / 1_000, 3)
         })}

      error ->
        error
    end
  end

  defp run(index, source_or_ast, opts) do
    opts = Keyword.merge(@default_opts, opts)

    with {:ok, query_fragment} <- query_fragment(source_or_ast, opts) do
      query_norm = Normalizer.normalize(query_fragment.ast)

      {fragments, fallback?, prefilter_strategy} =
        candidate_fragments(index, query_fragment, opts)

      results =
        fragments
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

      {:ok, results,
       %{
         query_subhashes: MapSet.size(query_fragment.sub_hashes),
         candidate_fragments: length(fragments),
         exact_scored_fragments: length(fragments),
         fallback_to_full_scan: fallback?,
         prefilter_strategy: prefilter_strategy
       }}
    end
  end

  defp candidate_fragments(index, query_fragment, opts) do
    case prefilter_strategy(opts) do
      :full_scan ->
        {FragmentStore.all(index.fragment_store), true, :full_scan}

      :subhash ->
        prefiltered_candidates(index, query_fragment)
    end
  end

  defp prefilter_strategy(opts) do
    if Keyword.get(opts, :force_full_scan, false) do
      :full_scan
    else
      case Keyword.get(opts, :prefilter) do
        :full_scan ->
          :full_scan

        :subhash ->
          :subhash

        :auto ->
          if(opts[:min_similarity] >= opts[:prefilter_min_similarity],
            do: :subhash,
            else: :full_scan
          )

        invalid ->
          raise ArgumentError, "unsupported similarity prefilter: #{inspect(invalid)}"
      end
    end
  end

  defp prefiltered_candidates(index, query_fragment) do
    hashes = MapSet.to_list(query_fragment.sub_hashes)
    source = Schema.fragments_source(index.fragment_store.prefix)
    files_source = Schema.files_source(index.fragment_store.prefix)

    candidates =
      from(fragment in {source, FragmentRecord},
        join: file in ^files_source,
        on: file.id == fragment.file_id,
        where: fragment.mass >= ^div(query_fragment.mass, 2),
        where: fragment.mass <= ^(query_fragment.mass * 2),
        where: has_any(fragment.sub_hashes, ^hashes),
        order_by: [asc: file.path, asc: fragment.line, asc: fragment.id],
        select: {fragment, file.source, file.path, file.ast}
      )
      |> index.fragment_store.repo.all()
      |> Enum.map(fn {record, source, path, file_ast} ->
        Hydration.fragment(record, source, path, nil, nil, file_ast)
      end)

    case candidates do
      [] -> {FragmentStore.all(index.fragment_store), true, :full_scan}
      _ -> {candidates, false, :subhash}
    end
  end

  defp query_fragment(source, opts) when is_binary(source) do
    parser_opts = [
      line: 1,
      columns: true,
      token_metadata: true,
      file: "<query>",
      emit_warnings: false
    ]

    with {:ok, ast} <- Exograph.ElixirParser.string_to_quoted(source, parser_opts) do
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

  defp subhash_overlap(fragment, query_fragment) do
    fragment.sub_hashes
    |> MapSet.intersection(query_fragment.sub_hashes)
    |> MapSet.size()
  end
end
