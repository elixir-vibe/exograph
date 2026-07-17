defmodule Exograph do
  @moduledoc """
  Local CodeQL-style code search for Elixir, backed by DuckDB/QuackDB and ExAST.

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
    Query,
    ReferenceHit,
    ShardedIndex,
    ShardTelemetry,
    Similarity,
    StructuralQuery,
    Text,
    TextHit
  }

  alias Exograph.Extractor.ExAST, as: ExASTExtractor

  alias Exograph.Storage.{FragmentStore, InvertedIndex, Schema, TreeStore}

  import Ecto.Query, only: [from: 2]

  @spec index(String.t() | [String.t()], keyword()) :: {:ok, Index.t()} | {:error, term()}
  def index(paths, opts \\ []) do
    do_index(ExASTExtractor.stream_paths(paths, extractor_opts(opts)), opts)
  end

  @doc false
  def index_sources(sources, opts \\ []) do
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
    Exograph.DuckDB.configure_threads!(
      Keyword.fetch!(opts, :repo),
      Keyword.get(opts, :duckdb_threads)
    )

    if Keyword.get(opts, :migrate?, false) do
      Exograph.DuckDB.migrate!(opts)
    end

    store_opts_without_migration = store_opts(opts) |> Keyword.put(:migrate?, false)
    batch_size = Keyword.get(opts, :index_batch_size, 2_000)

    with {:ok, inverted} <- InvertedIndex.new(store_opts_without_migration),
         {:ok, fragment_store} <- FragmentStore.new(store_opts_without_migration),
         {:ok, tree_store} <- TreeStore.new(store_opts_without_migration),
         {:ok, {inverted, fragment_store, tree_store}} <-
           put_fragment_stream(fragments, batch_size, inverted, fragment_store, tree_store),
         :ok <- FragmentStore.mark_package_version_complete(fragment_store) do
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

  @doc "Builds and validates the storage-independent plan for an Exograph query."
  @spec plan(Query.t()) :: Exograph.Query.Plan.t()
  def plan(%Query{} = query) do
    Exograph.DSL.Planner.plan(query)

    execution = if query.source == :fragment, do: :indexed_structural, else: :relational

    required_terms =
      if query.source == :fragment, do: DSL.Compiler.required_terms(query), else: []

    %Exograph.Query.Plan{
      query: query,
      execution: execution,
      hydration: if(query.source == :fragment, do: :indexed_fragments, else: :none),
      required_terms: required_terms
    }
  end

  @doc "Returns a bounded estimate of rows selected by the indexed candidate plan."
  @spec estimate_candidates(Index.t() | ShardedIndex.t(), Query.t(), keyword()) ::
          {:ok, Exograph.Query.Estimate.t()} | {:error, term()}
  def estimate_candidates(index, query, opts \\ [])

  def estimate_candidates(%Index{} = index, %Query{source: :fragment} = query, opts) do
    max_candidates = Keyword.get(opts, :max_candidates, 10_000)
    compiled = query |> DSL.Compiler.compile() |> compile()

    candidate_count =
      index
      |> DSL.Executor.structural_candidate_query(compiled,
        candidate_limit: max_candidates + 1
      )
      |> index.inverted.repo.all(timeout: :infinity)
      |> length()

    estimate =
      if candidate_count > max_candidates do
        %Exograph.Query.Estimate{value: max_candidates, relation: :gte}
      else
        %Exograph.Query.Estimate{value: candidate_count, relation: :eq}
      end

    {:ok, estimate}
  end

  def estimate_candidates(%Index{} = index, %Query{} = query, opts) do
    case count(index, query, opts) do
      {:ok, count} -> {:ok, %Exograph.Query.Estimate{value: count, relation: :eq}}
      :unknown -> {:error, :estimate_unavailable}
    end
  end

  def estimate_candidates(%ShardedIndex{shards: shards}, %Query{} = query, opts) do
    Enum.reduce_while(shards, {:ok, []}, fn shard, {:ok, estimates} ->
      result =
        Exograph.DuckDBShards.with_repo(shard, fn ->
          estimate_candidates(shard.index, query, opts)
        end)

      case result do
        {:ok, estimate} -> {:cont, {:ok, [estimate | estimates]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, estimates} ->
        relation = if Enum.any?(estimates, &(&1.relation == :gte)), do: :gte, else: :eq
        value = Enum.sum_by(estimates, & &1.value)
        {:ok, %Exograph.Query.Estimate{value: value, relation: relation}}

      {:error, _reason} = error ->
        error
    end
  end

  @doc "Hydrates an immutable source snapshot for a package version."
  @spec hydrate(Index.t() | ShardedIndex.t(), Exograph.PackageVersion.t(), keyword()) ::
          {:ok, Exograph.SourceSnapshot.t()} | {:error, term()}
  def hydrate(index, version, opts \\ [])

  def hydrate(%Index{} = index, %Exograph.PackageVersion{} = version, opts) do
    Exograph.Hydration.package_version(index, version, opts)
  end

  def hydrate(%ShardedIndex{shards: shards}, %Exograph.PackageVersion{} = version, opts) do
    Enum.reduce_while(shards, {:error, :package_version_not_found}, fn shard, _result ->
      result =
        Exograph.DuckDBShards.with_repo(shard, fn ->
          Exograph.Hydration.package_version(shard.index, version, opts)
        end)

      case result do
        {:ok, _snapshot} -> {:halt, result}
        {:error, :package_version_not_found} -> {:cont, result}
        {:error, _reason} -> {:halt, result}
      end
    end)
  end

  @spec all(Index.t(), Query.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def all(index, query, opts \\ [])

  def all(%ShardedIndex{} = index, %Exograph.Query{} = query, opts) do
    index
    |> fanout(:all, [query], opts)
    |> merge_hits(opts)
  end

  def all(%Index{} = index, %Exograph.Query{} = query, opts) do
    DSL.Executor.all(index, query, opts)
  end

  @doc false
  def count(index, query, opts \\ [])

  def count(%ShardedIndex{} = index, %Exograph.Query{} = query, opts) do
    index
    |> fanout(:count, [query], Keyword.drop(opts, [:limit, :skip]))
    |> sum_counts()
  end

  def count(%Index{} = index, %Exograph.Query{} = query, opts) do
    DSL.Executor.count(index, query, opts)
  end

  @spec search_callers(Index.t(), String.t(), keyword()) :: {:ok, [Exograph.CallEdge.t()]}
  def search_callers(index, callee, opts \\ [])

  def search_callers(%ShardedIndex{} = index, callee, opts) when is_binary(callee) do
    index
    |> fanout(:search_callers, [callee], opts)
    |> merge_hits(opts)
  end

  def search_callers(%Index{} = index, callee, opts) when is_binary(callee) do
    InvertedIndex.search_callers(index.inverted, callee, opts)
  end

  @spec search_callees(Index.t(), String.t(), keyword()) :: {:ok, [Exograph.CallEdge.t()]}
  def search_callees(index, caller, opts \\ [])

  def search_callees(%ShardedIndex{} = index, caller, opts) when is_binary(caller) do
    index
    |> fanout(:search_callees, [caller], opts)
    |> merge_hits(opts)
  end

  def search_callees(%Index{} = index, caller, opts) when is_binary(caller) do
    InvertedIndex.search_callees(index.inverted, caller, opts)
  end

  @doc "Explains similarity candidate retrieval and exact scoring work."
  @spec explain_similarity(Index.t(), String.t() | Macro.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def explain_similarity(%Index{} = index, source_or_ast, opts \\ []) do
    Similarity.explain(index, source_or_ast, opts)
  end

  @doc false
  @spec similar(Index.t(), String.t() | Macro.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def similar(%Index{} = index, source_or_ast, opts \\ []) do
    Similarity.search(index, source_or_ast, opts)
  end

  @doc "Explains literal source-text candidate retrieval."
  @spec explain_text(Index.t(), String.t(), keyword()) :: map()
  def explain_text(%Index{} = index, literal, opts \\ []) when is_binary(literal) do
    Exograph.DuckDB.TextSearch.explain_file_field(index.inverted, literal, :source, opts)
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
    {:ok, hits} = InvertedIndex.search_text_regex(index.inverted, regex, opts)

    hits
    |> annotate_text_hits(&Text.regex_locations(&1, regex))
    |> typed_hits(TextHit)
  end

  def search_text(%Index{} = index, literal, opts) when is_binary(literal) do
    {:ok, hits} = InvertedIndex.search_text(index.inverted, literal, opts)

    hits
    |> Enum.filter(&text_match?(&1.fragment.source || "", literal))
    |> annotate_text_hits(&Text.literal_locations(&1, literal))
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
    {:ok, hits} = InvertedIndex.search_comments(index.inverted, literal, opts)

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
    case InvertedIndex.search_definitions(index.inverted, partial_name, opts) do
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
    case InvertedIndex.search_references(index.inverted, partial_name, opts) do
      {:ok, hits} -> typed_hits(hits, ReferenceHit)
      {:error, _} -> {:ok, []}
    end
  end

  @doc false
  @spec compile(ExAST.Pattern.pattern() | ExAST.Selector.t()) :: StructuralQuery.t()
  def compile(%StructuralQuery{} = query), do: query
  def compile(%ExAST.Selector{} = selector), do: StructuralQuery.selector(selector)
  def compile(pattern), do: StructuralQuery.pattern(pattern)

  @doc """
  Returns DuckDB's analyzed candidate plan and measured verification pipeline
  for a structural query.

  ExAST remains the semantic authority. Candidate retrieval, hydration, and
  exact verification are measured separately so plan changes can be evaluated
  without conflating their costs.
  """
  def explain(index, query, opts \\ [])

  @spec explain(Index.t(), Query.t(), keyword()) :: map()
  def explain(%Index{} = index, %Query{} = query, _opts) do
    logical = plan(query)

    %{
      query: query,
      logical_plan: logical,
      execution: logical.execution,
      required_terms: logical.required_terms,
      index: %{prefix: index.inverted.prefix}
    }
  end

  @spec explain(Index.t(), ExAST.Pattern.pattern() | ExAST.Selector.t(), keyword()) :: map()
  def explain(%Index{} = index, pattern_or_selector, opts) do
    compiled = compile(pattern_or_selector)
    query = DSL.Executor.structural_candidate_query(index, compiled, opts)
    repo = index.inverted.repo
    {sql, params} = Ecto.Adapters.SQL.to_sql(:all, repo, query)
    analyzed = QuackDB.Profile.analyze!(repo, sql, params, timeout: :infinity)

    {candidate_us, candidate_ids} = :timer.tc(fn -> repo.all(query) end)

    {hydration_us, candidates} =
      :timer.tc(fn ->
        index
        |> DSL.Executor.stream_structural(compiled, opts)
        |> Enum.take(length(candidate_ids))
      end)

    {verification_us, verification} =
      :timer.tc(fn ->
        Enum.reduce(
          candidates,
          %{verified_fragments: 0, rejected_fragments: 0, matches: 0},
          fn candidate, metrics ->
            case StructuralQuery.verify(compiled, candidate) do
              {:ok, matches} ->
                %{
                  metrics
                  | verified_fragments: metrics.verified_fragments + 1,
                    matches: metrics.matches + length(matches)
                }

              :error ->
                %{metrics | rejected_fragments: metrics.rejected_fragments + 1}
            end
          end
        )
      end)

    metrics =
      Map.merge(verification, %{
        candidate_rows: length(candidate_ids),
        hydrated_fragments: length(candidates),
        candidate_ms: milliseconds(candidate_us),
        hydration_ms: milliseconds(hydration_us),
        verification_ms: milliseconds(verification_us),
        total_ms: milliseconds(candidate_us + hydration_us + verification_us)
      })

    %{
      logical: %{
        required_terms: compiled.required_terms |> MapSet.to_list() |> Enum.sort(),
        optional_terms: compiled.optional_terms |> MapSet.to_list() |> Enum.sort(),
        negative_terms: compiled.negative_terms |> MapSet.to_list() |> Enum.sort(),
        verifier: compiled.verifier
      },
      physical: %{
        sql: sql,
        parameter_count: length(params),
        analyze: analyzed,
        slowest_operators: QuackDB.Profile.slowest(analyzed)
      },
      metrics: metrics
    }
  end

  defp milliseconds(microseconds), do: Float.round(microseconds / 1_000, 3)

  @doc false
  @spec tree_nodes(Index.t(), Exograph.Fragment.id()) :: [Exograph.Tree.Node.t()]
  def tree_nodes(%Index{} = index, fragment_id) do
    TreeStore.nodes(index.tree_store, fragment_id)
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
          InvertedIndex.add(inverted, batch)
        end)

      {:ok, fragment_store} =
        Exograph.Hex.StageTimings.measure(:fragment_store_put, fn ->
          FragmentStore.put(fragment_store, batch)
        end)

      {:ok, tree_store} =
        Exograph.Hex.StageTimings.measure(:tree_store_put, fn ->
          TreeStore.put_fragments(tree_store, batch)
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

  defp extractor_opts(opts) do
    Keyword.drop(opts, [
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
      :static_atoms
    ])
  end

  defp sum_counts({:ok, counts}) when is_list(counts), do: {:ok, Enum.sum(counts)}
  defp sum_counts(:unknown), do: :unknown
  defp sum_counts({:error, _reason} = error), do: error

  defp fanout(%ShardedIndex{shards: shards}, function, args, opts) do
    limit = Keyword.get(opts, :limit, 50)
    skip = Keyword.get(opts, :skip, 0)

    shards
    |> candidate_shards(opts)
    |> Task.async_stream(
      fn shard ->
        {elapsed_us, result} =
          :timer.tc(fn ->
            Exograph.DuckDBShards.with_repo(shard, fn ->
              shard_opts = shard_opts(shard, opts, limit + skip)

              apply(
                __MODULE__,
                function,
                List.insert_at([shard_index(shard) | args], length(args) + 1, shard_opts)
              )
            end)
          end)

        ShardTelemetry.record(function, shard, Float.round(elapsed_us / 1000, 1), result)
        result
      end,
      max_concurrency: Keyword.get(opts, :shard_concurrency, length(shards)),
      timeout: Keyword.get(opts, :timeout, :infinity),
      ordered: false
    )
    |> Enum.reduce_while({:ok, []}, fn
      {:ok, {:ok, hits}}, {:ok, acc} when is_list(hits) -> {:cont, {:ok, [hits | acc]}}
      {:ok, {:ok, count}}, {:ok, acc} when is_integer(count) -> {:cont, {:ok, [count | acc]}}
      {:ok, :unknown}, _acc -> {:halt, :unknown}
      {:ok, {:error, reason}}, _acc -> {:halt, {:error, reason}}
      {:exit, reason}, _acc -> {:halt, {:error, reason}}
    end)
    |> then(fn
      {:ok, results} -> {:ok, results |> Enum.reverse() |> List.flatten()}
      result -> result
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
    |> Keyword.put(:skip, 0)
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
      package_versions_source = Schema.package_versions_source(prefix)

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
    packages_source = Schema.packages_source(prefix)

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

  defp hit_sort_key(%Exograph.Package{} = package) do
    {package.ecosystem, package.name, package.id}
  end

  defp hit_sort_key(%Exograph.PackageVersion{} = version) do
    {version.ecosystem, version.package_name, version.version, version.id}
  end

  defp hit_sort_key(hit) do
    fragment = hit_fragment(hit)
    score = hit_score(hit)

    {
      -score,
      hit_kind_rank(hit),
      fragment_path_rank(fragment),
      fragment_sort_value(fragment, :path),
      hit_line(hit, fragment),
      hit_id(hit, fragment)
    }
  end

  defp hit_fragment(%{fragment: fragment}), do: fragment
  defp hit_fragment({first, _joined}), do: hit_fragment(first)
  defp hit_fragment({first, _j1, _j2}), do: hit_fragment(first)
  defp hit_fragment({first, _j1, _j2, _j3}), do: hit_fragment(first)
  defp hit_fragment(_hit), do: nil

  defp hit_score(%{score: score}) when is_number(score), do: score
  defp hit_score({first, _joined}), do: hit_score(first)
  defp hit_score({first, _j1, _j2}), do: hit_score(first)
  defp hit_score({first, _j1, _j2, _j3}), do: hit_score(first)
  defp hit_score(_hit), do: 1.0

  defp hit_id(%{id: id}, _fragment) when not is_nil(id), do: id
  defp hit_id({_first, joined}, fragment), do: hit_id(joined, fragment)
  defp hit_id({_first, _j1, joined}, fragment), do: hit_id(joined, fragment)
  defp hit_id({_first, _j1, _j2, joined}, fragment), do: hit_id(joined, fragment)
  defp hit_id(_hit, fragment), do: Map.get(fragment || %{}, :id) || 0

  defp hit_kind_rank(%{match: %{node: {kind, _meta, _args}}}) do
    case kind do
      :def -> 0
      :defp -> 1
      :defmacro -> 2
      :defmacrop -> 3
      :defmodule -> 6
      _ -> 8
    end
  end

  defp hit_kind_rank(%{fragment: %{kind: kind}}) do
    case kind do
      :def -> 0
      :defp -> 1
      :defmacro -> 2
      :defmacrop -> 3
      :module -> 6
      :expression -> 9
      _ -> 8
    end
  end

  defp hit_kind_rank({first, _joined}), do: hit_kind_rank(first)
  defp hit_kind_rank({first, _j1, _j2}), do: hit_kind_rank(first)
  defp hit_kind_rank({first, _j1, _j2, _j3}), do: hit_kind_rank(first)
  defp hit_kind_rank(_hit), do: 8

  defp hit_line(%{match: %{node: {_kind, meta, _args}}}, _fragment) when is_list(meta),
    do: Keyword.get(meta, :line, 0)

  defp hit_line(%{match: %{line: line}}, _fragment) when is_integer(line), do: line
  defp hit_line({first, _joined}, fragment), do: hit_line(first, fragment)
  defp hit_line({first, _j1, _j2}, fragment), do: hit_line(first, fragment)
  defp hit_line({first, _j1, _j2, _j3}, fragment), do: hit_line(first, fragment)
  defp hit_line(_hit, fragment), do: fragment_sort_value(fragment, :line)

  defp fragment_path_rank(nil), do: 9

  defp fragment_path_rank(fragment) do
    path = Map.get(fragment, :file) || Map.get(fragment, :path) || ""

    cond do
      String.contains?(path, "/lib/") -> 0
      String.contains?(path, "/src/") -> 1
      String.ends_with?(path, ".ex") -> 2
      String.contains?(path, "/test/") -> 5
      String.contains?(path, "/bench") -> 6
      String.ends_with?(path, ".exs") -> 7
      true -> 4
    end
  end

  defp fragment_sort_value(nil, :path), do: ""
  defp fragment_sort_value(nil, :line), do: 0

  defp fragment_sort_value(fragment, :path),
    do: Map.get(fragment, :path) || Map.get(fragment, :file) || ""

  defp fragment_sort_value(fragment, :line), do: Map.get(fragment, :line) || 0

  defp annotate_text_hits(hits, locations) do
    Enum.map(hits, fn hit ->
      %{hit | match: locations.(hit.fragment.source || "")}
    end)
  end

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
