defmodule Exograph.Reach.SourceSmellAudit do
  @moduledoc """
  Audits Reach source-pattern smell checks against an Exograph index.

  This module is intended for Reach rule development: pass one or more Reach
  smell check modules, scan a broad Exograph corpus, and inspect real examples
  for false positives. It only consumes checks that expose Reach's
  `__reach_pattern_check__/0` metadata, which is produced by
  `Reach.Smell.Check.Source`.
  """

  import Ecto.Query

  alias Exograph.{DuckDBShards, Index, ShardedIndex}
  alias Exograph.Reach.SourceSmellAudit.{Finding, Pattern, Result}
  alias Exograph.Storage.{FragmentRecord, Schema}

  @default_limit 100
  @default_anchor_candidate_batch_size 1_000
  @default_exact_candidate_batch_size 8_000
  @default_max_anchor_candidates 10_000
  @candidate_fragment_fields [:id, :file_id, :node_pre, :node_post, :kind, :line]

  @doc """
  Scans `index` with source-pattern Reach smell `modules`.

  Options:

    * `:limit` - maximum findings returned, default `#{@default_limit}`.
    * `:candidate_batch_size` - fragment candidate page size. Defaults to
      `#{@default_anchor_candidate_batch_size}` for anchor mode and
      `#{@default_exact_candidate_batch_size}` for exact mode.
    * `:max_anchor_candidates` - in anchor mode, skip patterns whose best indexed
      anchor appears in more fragments than this, default `#{@default_max_anchor_candidates}`.
    * `:candidate_mode` - `:anchor` for fast first results or `:exact` to
      precompute candidates matching each pattern's full required term set.
    * `:verify_concurrency` - maximum concurrent AST verification tasks,
      default `min(System.schedulers_online(), 8)`.
  """
  @spec scan(Index.t() | ShardedIndex.t(), [module()], keyword()) :: {:ok, Result.t()}
  def scan(index, modules, opts \\ []) when is_list(modules) do
    scan_patterns(index, load_patterns!(modules), opts)
  end

  @doc "Scans `index` with already-loaded source-pattern Reach smell metadata."
  @spec scan_patterns(Index.t() | ShardedIndex.t(), [Pattern.t()], keyword()) :: {:ok, Result.t()}
  def scan_patterns(index, patterns, opts \\ []) when is_list(patterns) do
    case index do
      %ShardedIndex{shards: shards} ->
        scan_sharded(shards, patterns, opts)

      %Index{} = index ->
        {:ok, scan_index(index, patterns, opts)}
    end
  end

  @doc "Scans indexed source files with file-local Reach smell check modules."
  @spec scan_file_checks(Index.t() | ShardedIndex.t(), [module()], keyword()) :: {:ok, Result.t()}
  def scan_file_checks(index, modules, opts \\ []) when is_list(modules) do
    modules = Enum.map(modules, &ensure_reach_check!/1)

    case index do
      %ShardedIndex{shards: shards} ->
        scan_sharded_file_checks(shards, modules, opts)

      %Index{} = index ->
        {:ok, scan_index_file_checks(index, modules, opts)}
    end
  end

  @doc "Loads source-pattern metadata from Reach smell modules."
  @spec load_patterns!([module()]) :: [Pattern.t()]
  def load_patterns!(modules) when is_list(modules) do
    modules
    |> Enum.flat_map(&load_module_patterns!/1)
    |> Enum.with_index()
    |> Enum.map(fn {pattern, id} -> %{pattern | id: id} end)
  end

  defp load_module_patterns!(module) when is_atom(module) do
    ensure_source_pattern_check!(module)

    config = Reach.Smell.PatternConfig.normalize(module, module.__reach_pattern_check__())

    pattern_entries(module, :pattern, config.patterns) ++
      pattern_entries(module, :query, config.queries)
  end

  defp ensure_source_pattern_check!(module) do
    cond do
      not Code.ensure_loaded?(module) ->
        raise ArgumentError, "could not load Reach smell module #{inspect(module)}"

      not function_exported?(module, :__reach_pattern_check__, 0) ->
        raise ArgumentError,
              "#{inspect(module)} is not a Reach source-pattern smell check " <>
                "or does not expose __reach_pattern_check__/0"

      true ->
        :ok
    end
  end

  defp ensure_reach_check!(module) do
    cond do
      not Code.ensure_loaded?(module) ->
        raise ArgumentError, "could not load Reach smell module #{inspect(module)}"

      not function_exported?(module, :run, 1) ->
        raise ArgumentError, "#{inspect(module)} does not expose run/1"

      true ->
        module
    end
  end

  defp pattern_entries(module, source, entries) do
    Enum.map(entries, fn {pattern_or_fun, kind, message, prefilter} ->
      pattern = if source == :query, do: apply(module, pattern_or_fun, []), else: pattern_or_fun
      plan = ExAST.Index.plan(pattern)
      candidate_terms = MapSet.union(plan.required_terms, plan.optional_terms)

      %Pattern{
        module: module,
        source: source,
        kind: kind,
        message: message,
        prefilter: prefilter,
        pattern: compile_verifier_pattern(pattern),
        required_terms: candidate_terms
      }
    end)
  end

  defp compile_verifier_pattern(%ExAST.Selector{} = pattern), do: pattern

  defp compile_verifier_pattern(pattern) do
    if ExAST.Pattern.multi_node?(pattern) do
      pattern
    else
      ExAST.Pattern.compile(pattern)
    end
  end

  defp scan_sharded(shards, patterns, opts) do
    limit = Keyword.get(opts, :limit, @default_limit)

    {elapsed_us, result} =
      :timer.tc(fn ->
        shards
        |> Enum.reduce_while(%Result{scanned_patterns: length(patterns)}, fn shard, acc ->
          shard_result =
            DuckDBShards.with_repo(shard, fn -> scan_index(shard.index, patterns, opts) end)

          findings = merge_findings(acc.findings, shard_result.findings, limit)

          next = %{
            acc
            | findings: findings,
              candidate_count: acc.candidate_count + shard_result.candidate_count,
              skipped_patterns:
                merge_skipped_patterns(acc.skipped_patterns, shard_result.skipped_patterns)
          }

          if length(findings) >= limit, do: {:halt, next}, else: {:cont, next}
        end)
      end)

    {:ok, %{result | elapsed_ms: Float.round(elapsed_us / 1000, 1)}}
  end

  defp merge_findings(existing, incoming, limit) do
    incoming
    |> Enum.reduce(Enum.reverse(existing), fn finding, findings ->
      if length(findings) < limit, do: [finding | findings], else: findings
    end)
    |> Enum.reverse()
  end

  defp merge_skipped_patterns(left, right),
    do: Enum.uniq_by(Enum.concat(left, right), &skipped_pattern_key/1)

  defp scan_sharded_file_checks(shards, modules, opts) do
    limit = Keyword.get(opts, :limit, @default_limit)

    {elapsed_us, result} =
      :timer.tc(fn ->
        shards
        |> Enum.reduce_while(%Result{scanned_patterns: length(modules)}, fn shard, acc ->
          shard_result =
            DuckDBShards.with_repo(shard, fn ->
              scan_index_file_checks(shard.index, modules, opts)
            end)

          findings = merge_findings(acc.findings, shard_result.findings, limit)

          next = %{
            acc
            | findings: findings,
              candidate_count: acc.candidate_count + shard_result.candidate_count
          }

          if length(findings) >= limit, do: {:halt, next}, else: {:cont, next}
        end)
      end)

    {:ok, %{result | elapsed_ms: Float.round(elapsed_us / 1000, 1)}}
  end

  defp scan_index_file_checks(index, modules, opts) do
    limit = Keyword.get(opts, :limit, @default_limit)
    batch_size = Keyword.get(opts, :candidate_batch_size, @default_anchor_candidate_batch_size)

    {elapsed_us, {findings, candidate_count}} =
      :timer.tc(fn -> collect_file_check_findings(index, modules, opts, batch_size, limit) end)

    %Result{
      findings: findings,
      elapsed_ms: Float.round(elapsed_us / 1000, 1),
      candidate_count: candidate_count,
      scanned_patterns: length(modules),
      skipped_patterns: []
    }
  end

  defp collect_file_check_findings(index, modules, opts, batch_size, limit) do
    source_prefilters = source_prefilters(opts)

    file_candidate_batches(index, source_prefilters, batch_size)
    |> Enum.reduce_while({[], MapSet.new(), 0}, fn rows, {findings, seen, count} ->
      new_findings = Enum.flat_map(rows, &file_check_findings(&1, modules))
      {next_findings, next_seen} = add_findings(findings, seen, new_findings)
      next_findings = Enum.take(next_findings, limit)
      next_count = count + length(rows)

      if length(next_findings) >= limit do
        {:halt, {next_findings, next_count}}
      else
        {:cont, {next_findings, next_seen, next_count}}
      end
    end)
    |> finish_findings()
  end

  defp source_prefilters(opts) do
    opts
    |> Keyword.get(:source_prefilter, [])
    |> List.wrap()
    |> Enum.flat_map(fn value ->
      value
      |> to_string()
      |> String.split(",", trim: true)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
    end)
  end

  defp file_candidate_batches(index, source_prefilters, batch_size) do
    Stream.resource(
      fn -> nil end,
      fn cursor ->
        batch = file_candidate_batch(index, source_prefilters, cursor, batch_size)

        case batch do
          [] -> {:halt, cursor}
          rows -> {[rows], List.last(rows).id}
        end
      end,
      fn _cursor -> :ok end
    )
  end

  defp file_candidate_batch(index, source_prefilters, cursor, batch_size) do
    base =
      from(file in Schema.files_source(index.inverted.prefix),
        left_join: version in ^Schema.package_versions_source(index.inverted.prefix),
        on: version.id == file.package_version_id,
        left_join: package in ^Schema.packages_source(index.inverted.prefix),
        on: package.id == file.package_id,
        order_by: [asc: file.id],
        limit: ^batch_size,
        select: %{
          id: file.id,
          path: file.path,
          source: file.source,
          package: package.name,
          package_version: version.version
        }
      )

    query = if cursor, do: where(base, [file], file.id > ^cursor), else: base

    source_prefilters
    |> Enum.reduce(query, fn prefilter, query ->
      where(query, [file], like(file.source, ^"%#{prefilter}%"))
    end)
    |> index.inverted.repo.all(timeout: :infinity)
  end

  defp file_check_findings(file, modules) do
    with {:ok, temp_path} <- write_temp_source(file) do
      try do
        project = Reach.Project.from_sources([temp_path])

        Enum.flat_map(modules, fn module ->
          project
          |> module.run()
          |> Enum.map(&file_check_finding(&1, module, file, temp_path))
        end)
      after
        File.rm(temp_path)
      end
    else
      _error -> []
    end
  rescue
    ArgumentError -> []
  end

  defp write_temp_source(%{path: path, source: source}) when is_binary(source) do
    extension = Path.extname(path || "source.ex")

    temp_path =
      Path.join(
        System.tmp_dir!(),
        "exograph_reach_audit_#{System.unique_integer([:positive])}#{extension}"
      )

    case File.write(temp_path, source) do
      :ok -> {:ok, temp_path}
      error -> error
    end
  end

  defp write_temp_source(_file), do: :error

  defp file_check_finding(finding, module, file, temp_path) do
    line = finding.location |> to_string() |> location_line(temp_path)

    %Finding{
      check: module,
      kind: finding.kind,
      message: finding.message,
      package: file.package,
      package_version: file.package_version,
      file: file.path,
      file_id: file.id,
      fragment_id: nil,
      line: line,
      range: nil,
      match_fingerprint: nil,
      snippet: snippet(file.source, line),
      anchor_term: nil
    }
  end

  defp location_line(location, temp_path) do
    prefix = temp_path <> ":"

    if String.starts_with?(location, prefix) do
      location
      |> String.replace_prefix(prefix, "")
      |> String.split(":", parts: 2)
      |> hd()
      |> parse_line()
    else
      0
    end
  end

  defp parse_line(value) do
    case Integer.parse(value) do
      {line, _rest} -> line
      :error -> 0
    end
  end

  defp skipped_pattern_key(%Pattern{} = pattern),
    do: {pattern.module, pattern.kind, pattern.message, pattern.anchor_term, pattern.anchor_count}

  defp scan_index(%Index{} = index, patterns, opts) do
    {planned_patterns, skipped_patterns} = plan_patterns(index, patterns, opts)
    limit = Keyword.get(opts, :limit, @default_limit)

    {elapsed_us, {findings, candidate_count}} =
      :timer.tc(fn -> collect_findings(index, planned_patterns, opts, limit) end)

    findings = hydrate_finding_snippets(index, findings)

    %Result{
      findings: findings,
      elapsed_ms: Float.round(elapsed_us / 1000, 1),
      candidate_count: candidate_count,
      scanned_patterns: length(planned_patterns),
      skipped_patterns: skipped_patterns
    }
  end

  defp plan_patterns(index, patterns, opts) do
    term_ids = term_ids(index, patterns)
    term_counts = term_counts(index, term_ids)

    planned = Enum.map(patterns, &plan_pattern(&1, term_ids, term_counts))

    if exact_candidate_mode?(opts) do
      Enum.split_with(planned, fn
        %Pattern{missing_terms: [], required_term_ids: required_term_ids} ->
          MapSet.size(required_term_ids) > 0

        _pattern ->
          false
      end)
    else
      max_anchor_candidates =
        Keyword.get(opts, :max_anchor_candidates, @default_max_anchor_candidates)

      Enum.split_with(planned, fn
        %Pattern{anchor_count: count, missing_terms: []} when is_integer(count) ->
          count <= max_anchor_candidates

        _pattern ->
          false
      end)
    end
  end

  defp plan_pattern(%Pattern{} = pattern, term_ids, term_counts) do
    required_term_ids =
      pattern.required_terms
      |> MapSet.to_list()
      |> Enum.map(&Map.get(term_ids, &1))
      |> Enum.reject(&is_nil/1)
      |> MapSet.new()

    missing_terms = Enum.reject(pattern.required_terms, &Map.has_key?(term_ids, &1))
    anchor = anchor_term(pattern.required_terms, term_counts)

    %{
      pattern
      | required_term_ids: required_term_ids,
        missing_terms: missing_terms,
        anchor_term: anchor,
        anchor_id: Map.get(term_ids, anchor),
        anchor_count: Map.get(term_counts, anchor, :missing)
    }
  end

  defp anchor_term(required_terms, term_counts) do
    required_terms
    |> MapSet.to_list()
    |> Enum.min_by(&Map.get(term_counts, &1, 9_999_999_999), fn -> nil end)
  end

  defp term_ids(index, patterns) do
    terms = patterns |> Enum.flat_map(&MapSet.to_list(&1.required_terms)) |> Enum.uniq()

    from(term in Schema.terms_source(index.inverted.prefix),
      where: term.term in ^terms,
      select: {term.term, term.id}
    )
    |> index.inverted.repo.all()
    |> Map.new()
  end

  defp term_counts(_index, term_ids) when map_size(term_ids) == 0, do: %{}

  defp term_counts(index, term_ids) do
    id_to_term = Map.new(term_ids, fn {term, id} -> {id, term} end)
    ids = Map.keys(id_to_term)

    from(fragment_term in Schema.fragment_terms_source(index.inverted.prefix),
      where: fragment_term.term_id in ^ids,
      group_by: fragment_term.term_id,
      select: {fragment_term.term_id, count(fragment_term.fragment_id)}
    )
    |> index.inverted.repo.all()
    |> Map.new(fn {id, count} -> {Map.fetch!(id_to_term, id), count} end)
  end

  defp collect_findings(_index, [], _opts, _limit), do: {[], 0}

  defp collect_findings(index, patterns, opts, limit) do
    batch_size = candidate_batch_size(opts)

    candidate_batches(index, patterns, opts, batch_size)
    |> Enum.reduce_while({[], MapSet.new(), 0}, fn rows, {findings, seen, count} ->
      verified = verify_candidate_batch(rows, patterns, verify_concurrency(opts))

      {next_findings, next_seen} =
        Enum.reduce(verified, {findings, seen}, fn new_findings, {findings, seen} ->
          add_findings(findings, seen, new_findings)
        end)

      next_findings = Enum.take(next_findings, limit)
      next_count = count + length(rows)

      if length(next_findings) >= limit do
        {:halt, {next_findings, next_count}}
      else
        {:cont, {next_findings, next_seen, next_count}}
      end
    end)
    |> finish_findings()
  end

  defp add_findings(findings, seen, new_findings) do
    {new_findings, seen} =
      Enum.reduce(new_findings, {[], seen}, fn finding, {new_findings, seen} ->
        key = finding_key(finding)

        if MapSet.member?(seen, key) do
          {new_findings, seen}
        else
          {[finding | new_findings], MapSet.put(seen, key)}
        end
      end)

    findings = Enum.reduce(Enum.reverse(new_findings), findings, &[&1 | &2])
    {findings, seen}
  end

  defp finish_findings({findings, count}), do: {Enum.reverse(findings), count}
  defp finish_findings({findings, _seen, count}), do: {Enum.reverse(findings), count}

  defp finding_key(finding) do
    location_key = finding.range || finding.match_fingerprint || {:line, finding.line}

    {finding.check, finding.kind, finding.package, finding.package_version, finding.file,
     location_key, finding.message}
  end

  defp candidate_batch_size(opts) do
    case Keyword.get(opts, :candidate_batch_size) do
      batch_size when is_integer(batch_size) and batch_size > 0 ->
        batch_size

      _default ->
        if exact_candidate_mode?(opts) do
          @default_exact_candidate_batch_size
        else
          @default_anchor_candidate_batch_size
        end
    end
  end

  defp verify_concurrency(opts) do
    case Keyword.get(opts, :verify_concurrency) do
      concurrency when is_integer(concurrency) and concurrency > 0 -> concurrency
      _default -> min(System.schedulers_online(), 8)
    end
  end

  defp verify_candidate_batch(rows, patterns, concurrency) do
    rows
    |> Task.async_stream(
      fn {record, path, package_version, package, file_ast} ->
        fragment = candidate_fragment(record, path, package_version, file_ast)
        fragment_findings(fragment, package, patterns)
      end,
      max_concurrency: concurrency,
      ordered: true,
      timeout: :infinity
    )
    |> Enum.map(fn {:ok, findings} -> findings end)
  end

  defp candidate_batches(index, patterns, opts, batch_size) do
    if exact_candidate_mode?(opts) do
      exact_candidate_batches(index, patterns, batch_size)
    else
      anchor_candidate_batches(index, patterns, batch_size)
    end
  end

  defp exact_candidate_mode?(opts),
    do: Keyword.get(opts, :candidate_mode, :anchor) in [:exact, "exact"]

  defp anchor_candidate_batches(index, patterns, batch_size) do
    anchor_ids = patterns |> Enum.map(& &1.anchor_id) |> Enum.reject(&is_nil/1) |> Enum.uniq()

    Stream.resource(
      fn -> nil end,
      fn cursor ->
        batch = anchor_candidate_batch(index, anchor_ids, cursor, batch_size)

        case batch do
          [] -> {:halt, cursor}
          rows -> {[rows], List.last(rows) |> elem(0) |> Map.fetch!(:id)}
        end
      end,
      fn _cursor -> :ok end
    )
  end

  defp exact_candidate_batches(index, patterns, batch_size) do
    ids = exact_candidate_ids(index, patterns)

    ids
    |> Stream.chunk_every(batch_size)
    |> Stream.map(&candidate_rows(&1, index))
  end

  defp anchor_candidate_batch(index, anchor_ids, cursor, batch_size) do
    index
    |> anchor_candidate_ids(anchor_ids, cursor, batch_size)
    |> candidate_rows(index)
  end

  defp candidate_rows([], _index), do: []

  defp candidate_rows(ids, index) when is_list(ids) do
    from(fragment in {Schema.fragments_source(index.inverted.prefix), FragmentRecord},
      left_join: file in ^Schema.files_source(index.inverted.prefix),
      on: file.id == fragment.file_id,
      left_join: version in ^Schema.package_versions_source(index.inverted.prefix),
      on: version.id == fragment.package_version_id,
      left_join: package in ^Schema.packages_source(index.inverted.prefix),
      on: package.id == fragment.package_id,
      where: fragment.id in ^ids,
      order_by: [asc: fragment.id],
      select:
        {map(fragment, ^@candidate_fragment_fields), file.path, version.version, package.name,
         file.ast}
    )
    |> index.inverted.repo.all()
  end

  defp candidate_fragment(record, path, package_version, file_ast) do
    %{
      id: record.id,
      file_id: record.file_id,
      file: path,
      package_version: package_version,
      ast:
        Exograph.AST.Locator.slice(
          Exograph.Storage.Hydration.decode_file_ast(file_ast),
          record.node_pre,
          record.node_post
        ),
      kind: record.kind,
      line: record.line
    }
  end

  defp anchor_candidate_ids(index, anchor_ids, cursor, batch_size) do
    base =
      from(fragment_term in Schema.fragment_terms_source(index.inverted.prefix),
        where: fragment_term.term_id in ^anchor_ids,
        distinct: fragment_term.fragment_id,
        order_by: [asc: fragment_term.fragment_id],
        limit: ^batch_size,
        select: fragment_term.fragment_id
      )

    query =
      if cursor, do: where(base, [fragment_term], fragment_term.fragment_id > ^cursor), else: base

    index.inverted.repo.all(query)
  end

  defp exact_candidate_ids(index, patterns) do
    patterns
    |> Enum.map(&MapSet.to_list(&1.required_term_ids))
    |> Enum.uniq()
    |> minimal_required_term_groups()
    |> Enum.reduce(MapSet.new(), fn ids, acc ->
      ids
      |> exact_candidate_ids_for_group(index)
      |> Enum.reduce(acc, &MapSet.put(&2, &1))
    end)
    |> MapSet.to_list()
    |> Enum.sort()
  end

  defp minimal_required_term_groups(groups) do
    group_sets = Enum.map(groups, &MapSet.new/1)

    Enum.reject(groups, fn group ->
      group_set = MapSet.new(group)

      Enum.any?(group_sets, fn other ->
        MapSet.size(other) < MapSet.size(group_set) and MapSet.subset?(other, group_set)
      end)
    end)
  end

  defp exact_candidate_ids_for_group([], _index), do: []

  defp exact_candidate_ids_for_group(ids, index) do
    required_count = length(ids)

    from(fragment_term in Schema.fragment_terms_source(index.inverted.prefix),
      where: fragment_term.term_id in ^ids,
      group_by: fragment_term.fragment_id,
      having: count(fragment_term.term_id, :distinct) == ^required_count,
      select: fragment_term.fragment_id
    )
    |> index.inverted.repo.all()
  end

  defp fragment_findings(fragment, package, patterns) do
    if fragment.kind == :expression do
      named = Map.new(patterns, &{&1.id, &1.pattern})
      by_id = Map.new(patterns, &{&1.id, &1})

      fragment.ast
      |> ExAST.Patcher.find_many(named)
      |> Enum.map(&finding(fragment, package, Map.fetch!(by_id, &1.pattern), &1))
    else
      []
    end
  rescue
    ArgumentError -> []
  end

  defp finding(fragment, package, %Pattern{} = pattern, match) do
    range = match_range(match)
    line = match_line(match) || match_node_line(match) || fragment.line
    match_fingerprint = match_fingerprint(match)

    %Finding{
      check: pattern.module,
      kind: pattern.kind,
      message: pattern.message,
      package: package,
      package_version: fragment.package_version,
      file: fragment.file,
      file_id: fragment.file_id,
      fragment_id: fragment.id,
      line: line,
      range: range,
      match_fingerprint: match_fingerprint,
      snippet: nil,
      anchor_term: pattern.anchor_term
    }
  end

  defp hydrate_finding_snippets(_index, []), do: []

  defp hydrate_finding_snippets(index, findings) do
    sources = file_sources(index, findings)

    Enum.map(findings, fn %Finding{file_id: file_id, line: line} = finding ->
      source = Map.get(sources, file_id)
      %{finding | snippet: snippet(source, line)}
    end)
  end

  defp file_sources(index, findings) do
    ids = findings |> Enum.map(& &1.file_id) |> Enum.reject(&is_nil/1) |> Enum.uniq()

    if ids == [] do
      %{}
    else
      from(file in Schema.files_source(index.inverted.prefix),
        where: file.id in ^ids,
        select: {file.id, file.source}
      )
      |> index.inverted.repo.all()
      |> Map.new()
    end
  end

  defp match_range(%{range: %{start: start, end: stop}}) when is_list(start) and is_list(stop) do
    %{
      start_line: Keyword.get(start, :line),
      start_column: Keyword.get(start, :column),
      end_line: Keyword.get(stop, :line),
      end_column: Keyword.get(stop, :column)
    }
  end

  defp match_range(_match), do: nil

  defp match_fingerprint(%{node: node}) do
    node
    |> Macro.prewalk(fn
      {form, meta, args} when is_list(meta) -> {form, [], args}
      other -> other
    end)
    |> :erlang.term_to_binary()
    |> :erlang.phash2()
    |> Integer.to_string(16)
  end

  defp match_fingerprint(_match), do: nil

  defp match_line(%{range: %{start: start}}) when is_list(start), do: Keyword.get(start, :line)
  defp match_line(_match), do: nil

  defp match_node_line(%{node: {_form, meta, _args}}) when is_list(meta),
    do: Keyword.get(meta, :line)

  defp match_node_line(_match), do: nil

  defp snippet(source, line) when is_binary(source) and is_integer(line) do
    source
    |> String.split("\n", trim: false)
    |> Enum.slice(max(line - 3, 0), 5)
    |> Enum.join("\n")
  end

  defp snippet(_fragment, _line), do: nil
end
