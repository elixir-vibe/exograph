defmodule Exograph do
  @moduledoc """
  Local CodeQL-style code search for Elixir, backed by DuckDB/QuackDB or Postgres and ExAST.

  ## Quick start

      {:ok, index} = Exograph.index("lib", repo: MyApp.QuackDBRepo, migrate?: true)
      {:ok, hits} = Exograph.search(index, "Repo.get!(_, _)")

  ## DSL queries

      import Exograph.DSL
      query = from(f in Fragment, where: matches(f, "def _ do ... end"))
      {:ok, hits} = Exograph.all(index, query)

  ## Call graph

      {:ok, callers} = Exograph.search_callers(index, "Repo.transaction/1")
      {:ok, callees} = Exograph.search_callees(index, "MyApp.create_user/1")
  """

  alias Exograph.{
    CommentHit,
    DefinitionHit,
    DSL,
    Hit,
    Index,
    ReferenceHit,
    ShardedIndex,
    Similarity,
    StructuralQuery,
    Text,
    TextHit
  }

  alias Exograph.Extractor.ExAST, as: ExASTExtractor
  alias Exograph.Storage.Ecto.FragmentStore, as: EctoFragmentStore
  alias Exograph.Storage.Ecto.InvertedIndex, as: EctoInvertedIndex
  alias Exograph.Storage.Ecto.PackageRecord
  alias Exograph.Storage.Ecto.PackageVersionRecord
  alias Exograph.Storage.Ecto.TreeStore, as: EctoTreeStore

  import Ecto.Query, only: [from: 2]

  @spec index(String.t() | [String.t()], keyword()) :: {:ok, Index.t()} | {:error, term()}
  def index(paths, opts \\ []) do
    opts = normalize_backend(opts)
    do_index(ExASTExtractor.stream_paths(paths, extractor_opts(opts)), opts)
  end

  @doc false
  def index_sources(sources, opts \\ []) do
    opts = normalize_backend(opts)

    sources
    |> dedupe_sources(opts)
    |> ExASTExtractor.stream_sources(extractor_opts(opts))
    |> do_index(opts)
  end

  @doc false
  def open_sharded(manifest, opts \\ []) do
    manifest = Exograph.DuckDBShards.load_manifest(manifest)

    with {:ok, shards} <- Exograph.DuckDBShards.open(manifest, opts) do
      shard_indexes = Exograph.DuckDBShards.open_indexes(shards, opts)

      {:ok, ShardedIndex.new(shard_indexes, manifest: manifest)}
    end
  end

  defp dedupe_sources(sources, opts) do
    default_version = Keyword.get(opts, :package_version)

    Enum.uniq_by(sources, fn
      {path, _source} ->
        {path, default_version}

      {path, _source, source_opts} when is_list(source_opts) ->
        {path, Keyword.get(source_opts, :package_version, default_version)}
    end)
  end

  defp do_index(fragments, opts) do
    store_opts = store_opts(opts)

    store_opts =
      if opts[:backend] == :duckdb do
        Exograph.DuckDB.configure_threads!(
          Keyword.fetch!(opts, :repo),
          Keyword.get(opts, :duckdb_threads)
        )

        if Keyword.get(opts, :migrate?, false), do: Exograph.DuckDB.migrate!(opts)
        Keyword.put(store_opts, :migrate?, false)
      else
        store_opts
      end

    store_opts_without_migration = Keyword.put(store_opts, :migrate?, false)
    batch_size = Keyword.get(opts, :index_batch_size, 2_000)

    with {:ok, inverted} <- EctoInvertedIndex.new(store_opts),
         {:ok, fragment_store} <- EctoFragmentStore.new(store_opts_without_migration),
         {:ok, tree_store} <- EctoTreeStore.new(store_opts_without_migration),
         {:ok, {inverted, fragment_store, tree_store}} <-
           put_fragment_stream(fragments, batch_size, inverted, fragment_store, tree_store) do
      {:ok,
       %Index{
         inverted: inverted,
         fragment_store: fragment_store,
         tree_store: tree_store
       }}
    end
  end

  @spec search(Index.t() | term(), ExAST.Pattern.pattern() | ExAST.Selector.t(), keyword()) ::
          {:ok, [map()]} | {:error, term()}
  def search(index, pattern_or_selector, opts \\ [])

  def search(%ShardedIndex{} = index, pattern_or_selector, opts) do
    compiled = compile(pattern_or_selector)

    index
    |> fanout(:search, [compiled], opts)
    |> merge_hits(opts)
  end

  def search(%Index{} = index, pattern_or_selector, opts) do
    compiled = compile(pattern_or_selector)
    limit = Keyword.get(opts, :limit, 50)
    skip = Keyword.get(opts, :skip, 0)

    hits =
      index
      |> DSL.Executor.stream_structural(compiled, opts)
      |> Stream.flat_map(fn fragment ->
        case StructuralQuery.verify(compiled, fragment) do
          {:ok, matches} ->
            Enum.map(matches, &Hit.with_match(Hit.new(fragment: fragment, score: 1.0), &1))

          :error ->
            []
        end
      end)
      |> Stream.drop(skip)
      |> Enum.take(limit)

    {:ok, hits}
  end

  def search(_index, _pattern_or_selector, _opts) do
    {:error, :invalid_index}
  end

  @spec all(Index.t(), DSL.Query.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def all(index, query, opts \\ [])

  def all(%ShardedIndex{} = index, %DSL.Query{} = query, opts) do
    fanout(index, :all, [query], opts)
  end

  def all(%Index{} = index, %DSL.Query{source: :fragment} = query, opts) do
    DSL.Executor.all(index, query, opts)
  end

  def all(%Index{} = index, %DSL.Query{} = query, opts) do
    DSL.Executor.all(index, query, opts)
  end

  @spec search_callers(Index.t(), String.t(), keyword()) :: {:ok, [Exograph.CallEdge.t()]}
  def search_callers(index, callee, opts \\ [])

  def search_callers(%ShardedIndex{} = index, callee, opts) when is_binary(callee) do
    index
    |> fanout(:search_callers, [callee], opts)
    |> merge_hits(opts)
  end

  def search_callers(%Index{} = index, callee, opts) when is_binary(callee) do
    EctoInvertedIndex.search_callers(index.inverted, callee, opts)
  end

  @spec search_callees(Index.t(), String.t(), keyword()) :: {:ok, [Exograph.CallEdge.t()]}
  def search_callees(index, caller, opts \\ [])

  def search_callees(%ShardedIndex{} = index, caller, opts) when is_binary(caller) do
    index
    |> fanout(:search_callees, [caller], opts)
    |> merge_hits(opts)
  end

  def search_callees(%Index{} = index, caller, opts) when is_binary(caller) do
    EctoInvertedIndex.search_callees(index.inverted, caller, opts)
  end

  @doc false
  @spec similar(Index.t(), String.t() | Macro.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def similar(%Index{} = index, source_or_ast, opts \\ []) do
    Similarity.search(index, source_or_ast, opts)
  end

  @doc "Searches source text by literal string or regex."
  @spec search_text(Index.t(), String.t() | Regex.t(), keyword()) :: {:ok, [TextHit.t()]}
  def search_text(index, literal_or_regex, opts \\ [])

  def search_text(%ShardedIndex{} = index, literal_or_regex, opts) do
    index
    |> fanout(:search_text, [literal_or_regex], opts)
    |> merge_hits(opts)
  end

  def search_text(%Index{} = index, %Regex{} = regex, opts) do
    {:ok, hits} = EctoInvertedIndex.search_text_regex(index.inverted, regex, opts)
    typed_hits(hits, TextHit)
  end

  def search_text(%Index{} = index, literal, opts) when is_binary(literal) do
    {:ok, hits} = EctoInvertedIndex.search_text(index.inverted, literal, opts)

    hits
    |> Enum.filter(&text_match?(&1.fragment.source || "", literal))
    |> typed_hits(TextHit)
  end

  @doc false
  @spec search_comments(Index.t(), String.t(), keyword()) :: {:ok, [CommentHit.t()]}
  def search_comments(index, literal, opts \\ [])

  def search_comments(%ShardedIndex{} = index, literal, opts) when is_binary(literal) do
    index
    |> fanout(:search_comments, [literal], opts)
    |> merge_hits(opts)
  end

  def search_comments(%Index{} = index, literal, opts) when is_binary(literal) do
    {:ok, hits} = EctoInvertedIndex.search_comments(index.inverted, literal, opts)

    hits
    |> Enum.filter(&text_match?(comments_text(&1.fragment.source), literal))
    |> typed_hits(CommentHit)
  end

  @doc false
  @spec search_definitions(Index.t(), String.t(), keyword()) :: {:ok, [DefinitionHit.t()]}
  def search_definitions(index, partial_name, opts \\ [])

  def search_definitions(%ShardedIndex{} = index, partial_name, opts)
      when is_binary(partial_name) do
    index
    |> fanout(:search_definitions, [partial_name], opts)
    |> merge_hits(opts)
  end

  def search_definitions(%Index{} = index, partial_name, opts)
      when is_binary(partial_name) do
    case EctoInvertedIndex.search_definitions(index.inverted, partial_name, opts) do
      {:ok, hits} -> typed_hits(hits, DefinitionHit)
      {:error, _} -> {:ok, []}
    end
  end

  @doc false
  @spec search_references(Index.t(), String.t(), keyword()) :: {:ok, [ReferenceHit.t()]}
  def search_references(index, partial_name, opts \\ [])

  def search_references(%ShardedIndex{} = index, partial_name, opts)
      when is_binary(partial_name) do
    index
    |> fanout(:search_references, [partial_name], opts)
    |> merge_hits(opts)
  end

  def search_references(%Index{} = index, partial_name, opts)
      when is_binary(partial_name) do
    case EctoInvertedIndex.search_references(index.inverted, partial_name, opts) do
      {:ok, hits} -> typed_hits(hits, ReferenceHit)
      {:error, _} -> {:ok, []}
    end
  end

  @doc false
  @spec compile(ExAST.Pattern.pattern() | ExAST.Selector.t()) :: StructuralQuery.t()
  def compile(%StructuralQuery{} = query), do: query
  def compile(%ExAST.Selector{} = selector), do: StructuralQuery.selector(selector)
  def compile(pattern), do: StructuralQuery.pattern(pattern)

  @doc false
  @spec tree_nodes(Index.t(), Exograph.Fragment.id()) :: [Exograph.Tree.Node.t()]
  def tree_nodes(%Index{} = index, fragment_id) do
    EctoTreeStore.nodes(index.tree_store, fragment_id)
  end

  defp put_fragment_stream(fragments, batch_size, inverted, fragment_store, tree_store) do
    fragments
    |> chunk_fragments(batch_size)
    |> Enum.reduce_while({:ok, {inverted, fragment_store, tree_store}}, fn batch,
                                                                           {:ok,
                                                                            {inverted,
                                                                             fragment_store,
                                                                             tree_store}} ->
      {:ok, inverted} =
        Exograph.Hex.StageTimings.measure(:inverted_index_add, fn ->
          EctoInvertedIndex.add(inverted, batch)
        end)

      {:ok, fragment_store} =
        Exograph.Hex.StageTimings.measure(:fragment_store_put, fn ->
          EctoFragmentStore.put(fragment_store, batch)
        end)

      {:ok, tree_store} =
        Exograph.Hex.StageTimings.measure(:tree_store_put, fn ->
          EctoTreeStore.put_fragments(tree_store, batch)
        end)

      {:cont, {:ok, {inverted, fragment_store, tree_store}}}
    end)
  end

  defp chunk_fragments(fragments, batch_size) do
    Stream.chunk_while(
      fragments,
      {[], 0, nil},
      fn fragment, {batch, count, current_file} ->
        if count >= batch_size and current_file != fragment.file and batch != [] do
          {:cont, Enum.reverse(batch), {[fragment], 1, fragment.file}}
        else
          {:cont, {[fragment | batch], count + 1, fragment.file}}
        end
      end,
      fn
        {[], _count, _current_file} -> {:cont, []}
        {batch, _count, _current_file} -> {:cont, Enum.reverse(batch), {[], 0, nil}}
      end
    )
  end

  defp normalize_backend(opts) do
    case Keyword.fetch(opts, :backend) do
      :error ->
        Keyword.put(opts, :backend, inferred_backend(opts))

      {:ok, nil} ->
        Keyword.put(opts, :backend, inferred_backend(opts))

      {:ok, :postgres} ->
        opts

      {:ok, "postgres"} ->
        Keyword.put(opts, :backend, :postgres)

      {:ok, :duckdb} ->
        opts

      {:ok, "duckdb"} ->
        Keyword.put(opts, :backend, :duckdb)

      {:ok, other} ->
        raise ArgumentError, "unsupported backend #{inspect(other)}; use :postgres or :duckdb"
    end
  end

  defp inferred_backend(opts), do: Exograph.Backend.inferred(opts)

  defp extractor_opts(opts) do
    Keyword.drop(opts, [
      :backend,
      :repo,
      :prefix,
      :migrate?,
      :bm25?,
      :index_batch_size,
      :extractors
    ])
  end

  defp store_opts(opts) do
    Keyword.take(opts, [
      :repo,
      :prefix,
      :migrate?,
      :bm25?,
      :package,
      :package_version,
      :extractors,
      :defer_fragment_terms?,
      :duckdb_insert_buffer,
      :duckdb_build_mode,
      :duckdb_fragment_append,
      :static_atoms
    ])
  end

  defp fanout(%ShardedIndex{shards: shards}, function, args, opts) do
    limit = Keyword.get(opts, :limit, 50)
    skip = Keyword.get(opts, :skip, 0)

    shards
    |> candidate_shards(opts)
    |> Task.async_stream(
      fn shard ->
        Exograph.DuckDBShards.with_repo(shard, fn ->
          shard_opts = shard_opts(shard, opts, limit + skip)
          apply(__MODULE__, function, [shard_index(shard) | args] ++ [shard_opts])
        end)
      end,
      max_concurrency: Keyword.get(opts, :shard_concurrency, length(shards)),
      timeout: Keyword.get(opts, :timeout, :infinity),
      ordered: false
    )
    |> Enum.reduce_while({:ok, []}, fn
      {:ok, {:ok, hits}}, {:ok, acc} -> {:cont, {:ok, hits ++ acc}}
      {:ok, {:error, reason}}, _acc -> {:halt, {:error, reason}}
      {:exit, reason}, _acc -> {:halt, {:error, reason}}
    end)
  end

  defp candidate_shards(shards, opts) do
    case package_version_filter(opts) do
      nil -> shards
      package_version -> Enum.filter(shards, &shard_has_package_version?(&1, package_version))
    end
  end

  defp shard_opts(shard, opts, limit) do
    opts
    |> Keyword.put(:limit, limit)
    |> put_shard_package_version_filter(shard)
  end

  defp put_shard_package_version_filter(opts, shard) do
    case Keyword.get(opts, :package_version) do
      value when is_integer(value) ->
        opts

      nil ->
        opts

      package_key ->
        case shard_package_version_id(shard, package_key) do
          nil -> Keyword.put(opts, :package_version, -1)
          id -> Keyword.put(opts, :package_version, id)
        end
    end
  end

  defp shard_package_version_id(shard, package_key) do
    index = shard_index(shard)
    store = index.fragment_store
    repo = store.repo
    prefix = store.prefix

    package_id = shard_package_id(repo, prefix, package_name(package_key))

    if package_id do
      package_versions_source = {"#{prefix}_package_versions", PackageVersionRecord}

      query =
        from(pv in package_versions_source,
          where: pv.package_id == ^package_id,
          where: pv.version == ^package_version(package_key),
          select: pv.id,
          limit: 1
        )

      repo.one(query)
    end
  end

  defp shard_package_id(repo, prefix, name) do
    packages_source = {"#{prefix}_packages", PackageRecord}

    query =
      from(p in packages_source,
        where: p.name == ^name,
        select: p.id,
        limit: 1
      )

    repo.one(query)
  end

  defp package_version_filter(opts) do
    case Keyword.get(opts, :package_version) do
      nil -> nil
      value when is_integer(value) -> nil
      value -> value
    end
  end

  defp shard_has_package_version?(%{packages: packages}, package_version)
       when is_list(packages) do
    Enum.any?(packages, &package_version_match?(&1, package_version))
  end

  defp shard_has_package_version?(_shard, _package_version), do: true

  defp package_version_match?(package, package_version) do
    package_name(package) == package_name(package_version) and
      package_version(package) == package_version(package_version)
  end

  defp package_name(value) when is_map(value),
    do: Map.get(value, :name) || Map.get(value, :package_name)

  defp package_name(value) when is_list(value), do: Keyword.get(value, :name)
  defp package_name(_value), do: nil

  defp package_version(value) when is_map(value), do: Map.get(value, :version)
  defp package_version(value) when is_list(value), do: Keyword.get(value, :version)
  defp package_version(_value), do: nil

  defp shard_index(%Index{} = index), do: index
  defp shard_index(%{index: %Index{} = index}), do: index

  defp merge_hits({:error, reason}, _opts), do: {:error, reason}

  defp merge_hits({:ok, hits}, opts) do
    limit = Keyword.get(opts, :limit, 50)
    skip = Keyword.get(opts, :skip, 0)

    {:ok,
     hits
     |> Enum.sort_by(&hit_sort_key/1)
     |> Stream.drop(skip)
     |> Enum.take(limit)}
  end

  defp hit_sort_key(hit) do
    fragment = Map.get(hit, :fragment)
    score = Map.get(hit, :score, 1.0) || 1.0

    {
      -score,
      fragment_sort_value(fragment, :path),
      fragment_sort_value(fragment, :line),
      Map.get(hit, :id) || Map.get(fragment || %{}, :id) || 0
    }
  end

  defp fragment_sort_value(nil, :path), do: ""
  defp fragment_sort_value(nil, :line), do: 0
  defp fragment_sort_value(fragment, :path), do: Map.get(fragment, :path) || ""
  defp fragment_sort_value(fragment, :line), do: Map.get(fragment, :line) || 0

  defp typed_hits(hits, module) do
    {:ok,
     Enum.map(hits, fn
       %{__struct__: ^module} = hit -> hit
       hit -> module.new(fragment: hit.fragment, score: hit.score, match: hit.match)
     end)}
  end

  defp text_match?(source, literal) when is_binary(literal),
    do: Text.literal_match?(source, literal)

  defp comments_text(source) when is_binary(source), do: Exograph.File.comments_text(source)

  defp comments_text(_source), do: ""
end
