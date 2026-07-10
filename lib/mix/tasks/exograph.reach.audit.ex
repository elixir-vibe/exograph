defmodule Mix.Tasks.Exograph.Reach.Audit do
  @moduledoc """
  Audits Reach smell modules against an Exograph DuckDB index.

      mix exograph.reach.audit Reach.Smell.Checks.PipelineWaste \
        --duckdb-database /tmp/exograph-prod-shard-bench/hex_0.duckdb \
        --prefix hex_0 \
        --limit 50

  Each positional argument is a Reach smell module name. Source-pattern modules
  exposing `__reach_pattern_check__/0` use Exograph's indexed structural terms.
  Other file-local Reach checks run against indexed source files and can be
  narrowed with `--source-prefilter`.

  ## Options

    * `--repo` - Ecto repo module for a QuackDB-backed DuckDB repo
    * `--prefix` - Exograph table prefix (default: `exograph`)
    * `--quackdb-uri` - QuackDB URI when `--repo` is omitted
    * `--quackdb-token` - QuackDB token
    * `--duckdb-database` - managed DuckDB database path when `--quackdb-uri` is omitted
    * `--duckdb-threads` - DuckDB execution threads
    * `--manifest-path` - sharded DuckDB manifest path
    * `--duckdb-memory-limit` - DuckDB memory limit per opened shard/server
    * `--shard-pool-size` - DB connections per shard when opening a manifest
    * `--shard-port-base` - first local QuackDB port when opening a sharded manifest
    * `--limit` - maximum findings to print (default: 100)
    * `--candidate-batch-size` - fragment candidate page size (defaults to 1000 in anchor mode and 8000 in exact mode)
    * `--max-anchor-candidates` - in anchor mode, skip patterns whose best anchor is broader than this (default: 10000)
    * `--candidate-mode` - `anchor` for quick samples or `exact` for full required-term scans
    * `--verify-concurrency` - concurrent AST verifier tasks (default: min(scheduler count, 8))
    * `--json` - print compact JSON
    * `--pretty` - pretty-print JSON (implies `--json`)
    * `--group-by` - group text output by `kind`, `package`, or `check`
    * `--sample` - deterministically sample findings after scanning
    * `--show-skipped` - print skipped-pattern anchor summaries
    * `--source-prefilter` - for non-source Reach checks, only scan indexed files containing this text (comma-separated values are allowed)
    * `--save` - write the current audit JSON to a file
    * `--diff` - compare current findings against a previously saved audit JSON
  """

  use Mix.Task

  @shortdoc "Audits Reach source-pattern smells against an Exograph index"

  @impl true
  def run(args) do
    Mix.Task.run("app.start")

    {opts, modules, invalid} =
      OptionParser.parse(args,
        strict: [
          repo: :string,
          prefix: :string,
          quackdb_uri: :string,
          quackdb_token: :string,
          duckdb_database: :string,
          duckdb_threads: :integer,
          manifest_path: :string,
          duckdb_memory_limit: :string,
          shard_pool_size: :integer,
          shard_port_base: :integer,
          limit: :integer,
          candidate_batch_size: :integer,
          max_anchor_candidates: :integer,
          candidate_mode: :string,
          verify_concurrency: :integer,
          json: :boolean,
          pretty: :boolean,
          group_by: :string,
          sample: :integer,
          show_skipped: :boolean,
          source_prefilter: :string,
          save: :string,
          diff: :string
        ],
        aliases: [n: :limit]
      )

    if invalid != [] do
      Mix.raise("Invalid options: #{inspect(invalid)}")
    end

    if modules == [] do
      Mix.raise("Expected at least one Reach smell module name")
    end

    index = open_index!(opts)
    smell_modules = Enum.map(modules, &module!/1)

    {source_modules, file_check_modules} =
      Enum.split_with(smell_modules, &source_pattern_check?/1)

    result = audit_modules(index, source_modules, file_check_modules, opts)
    result = apply_presentation_opts(result, opts)
    maybe_save_result!(result, opts)

    case Keyword.get(opts, :diff) do
      nil -> print_result(result, opts)
      path -> print_diff!(path, result, opts)
    end
  end

  defp audit_modules(index, source_modules, file_check_modules, opts) do
    source_result =
      if source_modules == [] do
        empty_result()
      else
        {:ok, result} =
          Exograph.Reach.SourceSmellAudit.scan(index, source_modules,
            limit: Keyword.get(opts, :limit, 100),
            candidate_batch_size: Keyword.get(opts, :candidate_batch_size),
            max_anchor_candidates: Keyword.get(opts, :max_anchor_candidates, 10_000),
            candidate_mode: Keyword.get(opts, :candidate_mode, "anchor"),
            verify_concurrency: Keyword.get(opts, :verify_concurrency)
          )

        result
      end

    file_result =
      if file_check_modules == [] do
        empty_result()
      else
        {:ok, result} =
          Exograph.Reach.SourceSmellAudit.scan_file_checks(index, file_check_modules,
            limit: Keyword.get(opts, :limit, 100),
            candidate_batch_size: Keyword.get(opts, :candidate_batch_size),
            source_prefilter: Keyword.get(opts, :source_prefilter)
          )

        result
      end

    merge_results(source_result, file_result, Keyword.get(opts, :limit, 100))
  end

  defp empty_result, do: %Exograph.Reach.SourceSmellAudit.Result{}

  defp merge_results(left, right, limit) do
    %Exograph.Reach.SourceSmellAudit.Result{
      findings: Enum.take(left.findings ++ right.findings, limit),
      elapsed_ms: Float.round(left.elapsed_ms + right.elapsed_ms, 1),
      candidate_count: left.candidate_count + right.candidate_count,
      scanned_patterns: left.scanned_patterns + right.scanned_patterns,
      skipped_patterns: left.skipped_patterns ++ right.skipped_patterns
    }
  end

  defp source_pattern_check?(module) do
    Code.ensure_loaded?(module) and function_exported?(module, :__reach_pattern_check__, 0)
  end

  defp open_index!(opts) do
    if manifest_path = Keyword.get(opts, :manifest_path) do
      {:ok, index} =
        Exograph.open_sharded(manifest_path,
          duckdb_threads: Keyword.get(opts, :duckdb_threads),
          duckdb_memory_limit: Keyword.get(opts, :duckdb_memory_limit),
          pool_size: Keyword.get(opts, :shard_pool_size, 1),
          port_base: Keyword.get(opts, :shard_port_base, 9_700)
        )

      index
    else
      index_opts =
        opts
        |> Mix.Exograph.DuckDBOptions.opts()
        |> Keyword.put(:migrate?, false)

      {:ok, index} = Exograph.index([], index_opts)
      index
    end
  end

  defp apply_presentation_opts(result, opts) do
    case Keyword.get(opts, :sample) do
      nil ->
        result

      count when is_integer(count) and count >= 0 ->
        %{result | findings: sample(result.findings, count)}
    end
  end

  defp sample(_findings, 0), do: []
  defp sample(findings, count) when length(findings) <= count, do: findings

  defp sample(findings, count) do
    last = length(findings) - 1
    findings = List.to_tuple(findings)

    0..(count - 1)
    |> Enum.map(fn index -> elem(findings, round(index * last / max(count - 1, 1))) end)
  end

  defp maybe_save_result!(result, opts) do
    case Keyword.get(opts, :save) do
      nil ->
        :ok

      path ->
        File.mkdir_p!(Path.dirname(path))
        File.write!(path, Jason.encode!(result_json(result), pretty: true))
    end
  end

  defp print_result(result, opts) do
    if Keyword.get(opts, :json, false) or Keyword.get(opts, :pretty, false) do
      print_json(result, opts)
    else
      Mix.shell().info(summary_line(result))
      print_skipped_summary(result, opts)
      print_text_findings(result, opts)
    end
  end

  defp print_diff!(baseline_path, result, opts) do
    baseline = baseline_path |> File.read!() |> Jason.decode!()
    diff = diff_json(baseline, result_json(result))

    if Keyword.get(opts, :json, false) or Keyword.get(opts, :pretty, false) do
      print_json_value(diff, opts)
    else
      print_text_diff(diff, opts)
    end
  end

  defp diff_json(baseline, current) do
    baseline_findings = Map.get(baseline, "findings", [])
    current_findings = Map.get(current, :findings, [])

    baseline_by_key = Map.new(baseline_findings, &{finding_identity(&1), &1})
    current_by_key = Map.new(current_findings, &{finding_identity(&1), &1})

    baseline_keys = baseline_by_key |> Map.keys() |> MapSet.new()
    current_keys = current_by_key |> Map.keys() |> MapSet.new()

    new_keys = current_keys |> MapSet.difference(baseline_keys) |> Enum.sort()
    removed_keys = baseline_keys |> MapSet.difference(current_keys) |> Enum.sort()
    unchanged_count = current_keys |> MapSet.intersection(baseline_keys) |> MapSet.size()

    new_findings = Enum.map(new_keys, &Map.fetch!(current_by_key, &1))
    removed_findings = Enum.map(removed_keys, &Map.fetch!(baseline_by_key, &1))

    %{
      summary: %{
        baseline_count: map_size(baseline_by_key),
        current_count: map_size(current_by_key),
        new_count: length(new_findings),
        removed_count: length(removed_findings),
        unchanged_count: unchanged_count
      },
      new_findings: new_findings,
      removed_findings: removed_findings,
      groups: %{
        new: group_counts_from_json(new_findings),
        removed: group_counts_from_json(removed_findings)
      }
    }
  end

  defp finding_identity(finding) do
    {:finding, comparable_field(finding, :check), comparable_field(finding, :kind),
     comparable_field(finding, :package), comparable_field(finding, :package_version),
     comparable_field(finding, :file),
     comparable_field(finding, :range) || comparable_field(finding, :match_fingerprint) ||
       comparable_field(finding, :line), comparable_field(finding, :message)}
  end

  defp comparable_field(finding, :line), do: field(finding, :line)
  defp comparable_field(finding, :range), do: field(finding, :range)
  defp comparable_field(finding, :match_fingerprint), do: field(finding, :match_fingerprint)
  defp comparable_field(finding, key), do: finding |> field(key) |> comparable_string()

  defp comparable_string(nil), do: nil
  defp comparable_string(value), do: to_string(value)

  defp field(map, key) when is_map(map),
    do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp print_text_diff(diff, opts) do
    summary = diff.summary

    Mix.shell().info(
      "Diff: #{summary.new_count} new, #{summary.removed_count} removed, " <>
        "#{summary.unchanged_count} unchanged " <>
        "(baseline #{summary.baseline_count}, current #{summary.current_count})"
    )

    print_json_finding_group("new", diff.new_findings, opts)
    print_json_finding_group("removed", diff.removed_findings, opts)
  end

  defp print_json_finding_group(_label, [], _opts), do: :ok

  defp print_json_finding_group(label, findings, opts) do
    Mix.shell().info("\n## #{label} findings")

    findings
    |> maybe_group_json_findings(Keyword.get(opts, :group_by))
    |> Enum.each(fn {group, group_findings} ->
      if group do
        Mix.shell().info("\n### #{group} (#{length(group_findings)})")
      end

      Enum.each(group_findings, &print_json_finding/1)
    end)
  end

  defp maybe_group_json_findings(findings, nil), do: [{nil, findings}]

  defp maybe_group_json_findings(findings, group_by) do
    findings
    |> Enum.group_by(&json_finding_group(&1, group_by))
    |> Enum.sort_by(fn {group, group_findings} -> {to_string(group), length(group_findings)} end)
  end

  defp json_finding_group(finding, "kind"), do: field(finding, :kind)
  defp json_finding_group(finding, "check"), do: field(finding, :check)
  defp json_finding_group(finding, "package"), do: field(finding, :package) || "<unknown>"

  defp json_finding_group(_finding, group_by) do
    Mix.raise("Unsupported --group-by #{inspect(group_by)}. Use kind, package, or check.")
  end

  defp print_json_finding(finding) do
    Mix.shell().info([
      to_string(field(finding, :kind)),
      " ",
      to_string(field(finding, :package) || "<unknown>"),
      " ",
      to_string(field(finding, :file) || "<unknown>"),
      ":",
      to_string(field(finding, :line) || 0),
      " ",
      to_string(field(finding, :check)),
      "\n  ",
      to_string(field(finding, :message))
    ])

    if snippet = field(finding, :snippet) do
      Mix.shell().info("\n" <> indent(snippet) <> "\n")
    end
  end

  defp print_json(result, opts), do: print_json_value(result_json(result), opts)

  defp print_json_value(value, opts) do
    if Keyword.get(opts, :pretty, false) do
      Mix.shell().info(Jason.encode!(value, pretty: true))
    else
      Mix.shell().info(Jason.encode!(value))
    end
  end

  defp summary_line(result) do
    "#{length(result.findings)} finding(s), #{result.candidate_count} candidate(s), " <>
      "#{result.scanned_patterns} pattern(s), #{result.elapsed_ms}ms"
  end

  defp print_skipped_summary(result, opts) do
    if result.skipped_patterns != [] do
      Mix.shell().info(
        "#{length(result.skipped_patterns)} pattern(s) skipped by anchor threshold"
      )

      if Keyword.get(opts, :show_skipped, false) do
        result.skipped_patterns
        |> skipped_summaries()
        |> Enum.each(fn summary ->
          Mix.shell().info(
            "  #{inspect(summary.kind)} #{summary.check} anchor=#{summary.anchor_term || "<none>"} count=#{inspect(summary.anchor_count)}"
          )
        end)
      end
    end
  end

  defp print_text_findings(result, opts) do
    case Keyword.get(opts, :group_by) do
      nil ->
        Enum.each(result.findings, &print_finding/1)

      group_by ->
        result.findings
        |> Enum.group_by(&finding_group(&1, group_by))
        |> Enum.sort_by(fn {group, findings} -> {to_string(group), length(findings)} end)
        |> Enum.each(fn {group, findings} ->
          Mix.shell().info("\n## #{group_by}: #{group} (#{length(findings)})")
          Enum.each(findings, &print_finding/1)
        end)
    end
  end

  defp print_finding(finding) do
    Mix.shell().info([
      inspect(finding.kind),
      " ",
      finding.file || "<unknown>",
      ":",
      to_string(finding.line || 0),
      " ",
      inspect(finding.check),
      "\n  ",
      finding.message
    ])

    if finding.snippet do
      Mix.shell().info("\n" <> indent(finding.snippet) <> "\n")
    end
  end

  defp result_json(result) do
    %{
      elapsed_ms: result.elapsed_ms,
      candidate_count: result.candidate_count,
      scanned_patterns: result.scanned_patterns,
      skipped_patterns: skipped_summaries(result.skipped_patterns),
      groups: group_counts(result.findings),
      findings: Enum.map(result.findings, &finding_json/1)
    }
  end

  defp finding_json(finding) do
    %{
      check: inspect(finding.check),
      kind: finding.kind,
      message: finding.message,
      package: finding.package,
      package_version: finding.package_version,
      file: finding.file,
      line: finding.line,
      range: finding.range,
      match_fingerprint: finding.match_fingerprint,
      snippet: finding.snippet,
      anchor_term: finding.anchor_term
    }
  end

  defp skipped_summaries(patterns) do
    patterns
    |> Enum.map(fn pattern ->
      %{
        check: inspect(pattern.module),
        kind: pattern.kind,
        message: pattern.message,
        anchor_term: pattern.anchor_term,
        anchor_count: pattern.anchor_count,
        missing_terms: pattern.missing_terms
      }
    end)
    |> Enum.sort_by(fn summary ->
      {summary.check, to_string(summary.kind), anchor_count_sort(summary.anchor_count)}
    end)
  end

  defp anchor_count_sort(count) when is_integer(count), do: count
  defp anchor_count_sort(_count), do: 9_999_999_999

  defp group_counts(findings) do
    %{
      by_kind: count_by(findings, & &1.kind),
      by_check: count_by(findings, &inspect(&1.check)),
      by_package: count_by(findings, &(&1.package || "<unknown>"))
    }
  end

  defp group_counts_from_json(findings) do
    %{
      by_kind: count_by(findings, &field(&1, :kind)),
      by_check: count_by(findings, &field(&1, :check)),
      by_package: count_by(findings, &(field(&1, :package) || "<unknown>"))
    }
  end

  defp count_by(values, fun) do
    values
    |> Enum.frequencies_by(fun)
    |> Enum.map(fn {value, count} -> %{value: value, count: count} end)
    |> Enum.sort_by(fn %{value: value, count: count} -> {-count, to_string(value)} end)
  end

  defp finding_group(finding, "kind"), do: finding.kind
  defp finding_group(finding, "check"), do: inspect(finding.check)
  defp finding_group(finding, "package"), do: finding.package || "<unknown>"

  defp finding_group(_finding, group_by) do
    Mix.raise("Unsupported --group-by #{inspect(group_by)}. Use kind, package, or check.")
  end

  defp indent(text) do
    text
    |> String.split("\n")
    |> Enum.map_join("\n", &["  ", &1])
  end

  defp module!(name) do
    name
    |> String.split(".")
    |> Module.concat()
  end
end
