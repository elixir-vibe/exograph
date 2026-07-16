defmodule Exograph.Web.APIController do
  @moduledoc false
  use Phoenix.Controller, formats: [:json]

  import Ecto.Query

  alias Exograph.{Index, ShardedIndex}

  alias Exograph.Storage.Schema

  alias Exograph.Web.{Health, QueryExecutor, QueryTelemetry, SearchResult}

  @stats_tables [
    :packages,
    :package_versions,
    :files,
    :fragments,
    :fragment_terms,
    :definitions,
    :references,
    :comments,
    :call_edges,
    :terms
  ]
  @search_timeout_ms 20_000

  def search(conn, params) do
    index = index()
    pattern = params["pattern"] || ""
    mode = search_mode(params["mode"], pattern)
    limit = parse_limit(params["limit"])
    cursor = decode_cursor(params["cursor"])
    package_id = params["package_id"]

    opts = search_opts(mode, cursor, limit, package_id)

    {elapsed_us, result} =
      :timer.tc(fn ->
        case mode do
          "text" ->
            case Exograph.search_text(index, pattern, opts) do
              {:ok, hits} -> {:ok, hits, nil}
              {:error, reason} -> {:error, reason}
            end

          "regex" ->
            case Regex.compile(pattern) do
              {:ok, regex} ->
                case Exograph.search_text(index, regex, opts) do
                  {:ok, hits} -> {:ok, hits, nil}
                  {:error, reason} -> {:error, reason}
                end

              {:error, reason} ->
                {:error, "Invalid regex: #{inspect(reason)}"}
            end

          _ ->
            search_structural(index, pattern, opts)
        end
      end)

    elapsed_ms = Float.round(elapsed_us / 1000, 1)

    QueryTelemetry.record(
      mode,
      pattern,
      elapsed_ms,
      result_status(result),
      result_count(result),
      %{
        endpoint: "/api/search"
      }
    )

    case result do
      {:ok, hits, meta} ->
        next_cursor = next_search_cursor(mode, hits, cursor, limit)

        payload = %{
          results: Enum.map(hits, &serialize_result/1),
          count: length(hits),
          elapsed_ms: elapsed_ms,
          next_cursor: next_cursor
        }

        json(conn, maybe_put_meta(payload, meta))

      {:error, reason} ->
        api_error(conn, 400, "invalid_search", reason)
    end
  end

  def query(conn, params) do
    index = index()
    query_input = params["query"] || ""
    cursor = decode_cursor(params["cursor"])
    query = decode_query_input(query_input)
    query_label = if is_binary(query_input), do: query_input, else: Jason.encode!(query_input)

    {elapsed_us, result} =
      :timer.tc(fn ->
        with {:ok, decoded_query} <- query do
          QueryExecutor.execute(index, decoded_query, query_cursor_opts(cursor))
        end
      end)

    case result do
      {:ok, hits, elapsed_ms, effective_limit, _total, meta} ->
        QueryTelemetry.record("dsl", query_label, elapsed_ms, :ok, length(hits), %{
          endpoint: "/api/query"
        })

        next_cursor = next_query_cursor(hits, cursor, effective_limit)

        json(conn, %{
          results: Enum.map(hits, &serialize_result/1),
          count: length(hits),
          elapsed_ms: elapsed_ms,
          next_cursor: next_cursor,
          meta: meta
        })

      {:error, reason} ->
        QueryTelemetry.record(
          "dsl",
          query_label,
          Float.round(elapsed_us / 1000, 1),
          :error,
          0,
          %{
            endpoint: "/api/query"
          }
        )

        api_error(conn, 400, "invalid_query", reason)
    end
  end

  def plan(conn, %{"query" => query_input}) do
    index = index()

    with {:ok, query} <- decode_query_object(query_input),
         {:ok, estimate} <- Exograph.estimate_candidates(index, query) do
      response = %Exograph.API.PlanResponse{
        plan: Exograph.plan(query),
        estimate: estimate,
        index: plan_index(index)
      }

      json(conn, JSONCodec.dump(response))
    else
      {:error, reason} -> api_error(conn, 400, "invalid_query", reason)
    end
  rescue
    error in ArgumentError -> api_error(conn, 400, "invalid_query", Exception.message(error))
  end

  def plan(conn, _params), do: api_error(conn, 400, "invalid_query", "query is required")

  defp decode_query_input(query) when is_binary(query), do: {:ok, query}

  defp decode_query_input(query) when is_map(query), do: decode_query_object(query)
  defp decode_query_input(_query), do: {:error, "query must be a DSL string or query object"}

  defp decode_query_object(query) when is_map(query) do
    with {:ok, decoded} <- Exograph.Query.from_map(query),
         {:ok, validated} <- Exograph.Query.validate(decoded) do
      {:ok, validated}
    end
  end

  defp decode_query_object(_query), do: {:error, "query must be a versioned query object"}

  def hydrate(conn, params) do
    with {:ok, request} <- Exograph.Web.HydrateRequest.from_map(params),
         version <-
           Exograph.PackageVersion.new(
             ecosystem: request.ecosystem,
             name: request.package_name,
             version: request.version
           ),
         {:ok, snapshot} <- Exograph.hydrate(index(), version, hydration_opts(request)) do
      json(conn, JSONCodec.dump(snapshot))
    else
      {:error, :package_version_not_found} ->
        api_error(conn, 404, "package_version_not_found", "package version not found")

      {:error, {:snapshot_limit_exceeded, dimension, actual, limit}} ->
        api_error(conn, 413, "snapshot_limit_exceeded", %{
          message: "hydrated snapshot exceeds the configured #{dimension} limit",
          dimension: dimension,
          actual: actual,
          limit: limit
        })

      {:error, reason} ->
        api_error(conn, 400, "invalid_hydration_request", reason)
    end
  end

  defp hydration_opts(request) do
    Application.get_env(:exograph, :hydration, [])
    |> Keyword.put(:paths, request.paths)
  end

  def capabilities(conn, _params) do
    hydration_limits =
      :exograph
      |> Application.get_env(:hydration, [])
      |> Exograph.Hydration.limits()

    json(conn, Map.put(Exograph.Query.capabilities(), :hydration_limits, hydration_limits))
  end

  def health(conn, _params) do
    json(conn, Health.payload(index()))
  end

  def packages(conn, _params) do
    json(conn, package_payload(index()))
  end

  def stats(conn, _params) do
    json(conn, stats_payload(index()))
  end

  defp index, do: Application.get_env(:exograph, :web_index)

  defp result_status({:ok, _hits, _meta}), do: :ok
  defp result_status({:error, _reason}), do: :error

  defp result_count({:ok, hits, _meta}), do: length(hits)
  defp result_count({:error, _reason}), do: 0

  defp search_structural(index, pattern, opts) do
    cond do
      dsl_query?(pattern) ->
        execute_structural_dsl(index, pattern, opts)

      shorthand_query?(pattern) ->
        execute_structural_dsl(index, expand_shorthand_query!(pattern, opts), opts)

      true ->
        case Exograph.search(index, pattern, opts) do
          {:ok, hits} -> {:ok, hits, nil}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp execute_structural_dsl(index, pattern, opts) do
    case QueryExecutor.execute(index, pattern, Keyword.put(opts, :mode, "structural")) do
      {:ok, hits, _elapsed_ms, _effective_limit, _total, meta} -> {:ok, hits, meta}
      {:error, reason} -> {:error, reason}
    end
  end

  defp dsl_query?(pattern) when is_binary(pattern) do
    trimmed = String.trim(pattern)
    String.starts_with?(trimmed, "from(") or String.starts_with?(trimmed, "from ")
  end

  defp dsl_query?(_pattern), do: false

  defp shorthand_query?(pattern) when is_binary(pattern) do
    trimmed = String.trim(pattern)
    String.starts_with?(trimmed, "matches(") or String.starts_with?(trimmed, "contains(")
  end

  defp shorthand_query?(_pattern), do: false

  defp expand_shorthand_query!(pattern, opts) do
    limit = Keyword.get(opts, :limit, QueryExecutor.default_limit())

    case Regex.run(
           ~r/^\s*(matches|contains)\(\s*([[:alpha:]_][[:alnum:]_]*)\s*,\s*(.*)\)\s*$/s,
           pattern
         ) do
      [_, kind, binding, ast_pattern] ->
        ast_pattern = shorthand_pattern(ast_pattern)

        ~s|from(#{binding} in Fragment, where: #{kind}(#{binding}, #{inspect(ast_pattern)}), limit: #{limit})|

      _ ->
        pattern
    end
  end

  defp shorthand_pattern(pattern) do
    pattern = String.trim(pattern)

    if String.starts_with?(pattern, "\"") do
      case Code.string_to_quoted(pattern,
             static_atoms_encoder: fn name, _metadata ->
               {:ok, {:__exograph_query_identifier__, name}}
             end
           ) do
        {:ok, value} when is_binary(value) -> value
        _ -> pattern
      end
    else
      pattern
    end
  end

  defp api_error(conn, status, code, reason) do
    {message, details} = error_description(reason)
    response = Exograph.API.ErrorResponse.new(code, message, details)
    conn |> put_status(status) |> json(JSONCodec.dump(response))
  end

  defp error_description(%{message: message} = reason) when is_binary(message),
    do: {message, Map.delete(reason, :message)}

  defp error_description(%{"message" => message} = reason) when is_binary(message),
    do: {message, Map.delete(reason, "message")}

  defp error_description(reason) when is_binary(reason), do: {reason, %{}}
  defp error_description(reason), do: {inspect(reason), %{}}

  defp plan_index(%Index{} = index),
    do: %{kind: :single, prefix: index.inverted.prefix, shard_count: 1}

  defp plan_index(%ShardedIndex{shards: shards}),
    do: %{kind: :sharded, shard_count: length(shards)}

  defp maybe_put_meta(payload, nil), do: payload
  defp maybe_put_meta(payload, meta), do: Map.put(payload, :meta, meta)

  defp search_mode(nil, pattern), do: inferred_mode(pattern)
  defp search_mode("", pattern), do: inferred_mode(pattern)
  defp search_mode("auto", pattern), do: inferred_mode(pattern)
  defp search_mode(mode, _pattern), do: mode

  defp inferred_mode(pattern) do
    if structural_query?(pattern), do: "structural", else: "text"
  end

  defp structural_query?(pattern) when is_binary(pattern) do
    trimmed = String.trim(pattern)

    String.starts_with?(trimmed, "from(") or
      String.starts_with?(trimmed, "from ") or
      String.contains?(trimmed, "...") or
      String.contains?(trimmed, "_") or
      String.starts_with?(trimmed, "def ") or
      String.starts_with?(trimmed, "defp ") or
      String.starts_with?(trimmed, "fn ")
  end

  defp structural_query?(_pattern), do: false

  defp package_payload(%ShardedIndex{shards: shards}) do
    packages =
      shards
      |> Enum.flat_map(fn shard ->
        Exograph.DuckDBShards.with_repo(shard, fn -> package_rows(shard_index(shard)) end)
      end)
      |> Enum.group_by(& &1.name)
      |> Enum.map(fn {_name, rows} ->
        first = hd(rows)
        %{id: first.id, name: first.name, fragments: Enum.sum_by(rows, & &1.fragments)}
      end)
      |> Enum.sort_by(& &1.fragments, :desc)

    %{packages: packages, total: length(packages)}
  end

  defp package_payload(index) do
    packages = package_rows(index)
    %{packages: packages, total: length(packages)}
  end

  defp package_rows(index) do
    prefix = index.inverted.prefix
    repo = index.inverted.repo

    from(p in Schema.packages_source(prefix),
      left_join: f in ^Schema.fragments_source(prefix),
      on: f.package_id == p.id,
      group_by: [p.id, p.name],
      order_by: [desc: count(f.id)],
      select: %{id: p.id, name: p.name, fragments: count(f.id)}
    )
    |> repo.all(timeout: 30_000)
  end

  defp stats_payload(%ShardedIndex{shards: shards}) do
    counts =
      Enum.reduce(shards, zero_counts(), fn shard, acc ->
        shard_counts =
          Exograph.DuckDBShards.with_repo(shard, fn -> table_counts(shard_index(shard)) end)

        Map.merge(acc, shard_counts, fn _key, left, right -> left + right end)
      end)

    Map.put(counts, "prefix", Application.get_env(:exograph, :web_prefix))
  end

  defp stats_payload(index), do: Map.put(table_counts(index), "prefix", index.inverted.prefix)

  defp zero_counts do
    Map.new(@stats_tables, fn table -> {Atom.to_string(table), 0} end)
  end

  defp table_counts(index) do
    prefix = index.inverted.prefix
    repo = index.inverted.repo

    Map.new(@stats_tables, fn table ->
      {Atom.to_string(table),
       repo.aggregate(Schema.source(table, prefix), :count, timeout: 30_000)}
    end)
  end

  defp shard_index(%{index: index}), do: index
  defp shard_index(index), do: index

  defp search_opts(mode, cursor, limit, package_id) do
    [limit: limit, timeout: @search_timeout_ms]
    |> Keyword.merge(cursor_opts(mode, cursor))
    |> Kernel.++(scope_opts(package_id))
  end

  defp cursor_opts(mode, {:keyset, cursor}) when mode not in ["text", "regex"],
    do: [cursor: cursor, skip: 0]

  defp cursor_opts(_mode, {:offset, skip}), do: [skip: skip]
  defp cursor_opts(_mode, _cursor), do: [skip: 0]

  defp query_cursor_opts({:keyset, cursor}), do: [cursor: cursor, skip: 0]
  defp query_cursor_opts({:offset, skip}), do: [skip: skip]

  defp next_search_cursor(mode, hits, cursor, limit) when mode in ["text", "regex"] do
    if length(hits) == limit, do: encode_offset_cursor(offset(cursor) + limit), else: nil
  end

  defp next_search_cursor(_mode, hits, _cursor, limit) do
    if length(hits) == limit, do: hits |> List.last() |> encode_keyset_cursor(), else: nil
  end

  defp next_query_cursor(hits, _cursor, limit) do
    if length(hits) >= limit, do: hits |> List.last() |> encode_keyset_cursor(), else: nil
  end

  defp encode_offset_cursor(offset) when is_integer(offset),
    do: Base.url_encode64("#{offset}", padding: false)

  defp encode_keyset_cursor(hit) do
    case cursor_fragment(hit) do
      %{mass: mass, id: id} when is_integer(mass) and is_integer(id) ->
        {mass, id}
        |> :erlang.term_to_binary()
        |> Base.url_encode64(padding: false)

      _ ->
        nil
    end
  end

  defp decode_cursor(nil), do: {:offset, 0}
  defp decode_cursor(""), do: {:offset, 0}

  defp decode_cursor(encoded) do
    with {:ok, binary} <- Base.url_decode64(encoded, padding: false) do
      decode_cursor_binary(binary)
    else
      _ -> {:offset, 0}
    end
  end

  defp decode_cursor_binary(binary) do
    case Integer.parse(binary) do
      {offset, ""} -> {:offset, offset}
      _ -> decode_keyset_cursor(binary)
    end
  end

  defp decode_keyset_cursor(binary) do
    case :erlang.binary_to_term(binary, [:safe]) do
      {mass, id} when is_integer(mass) and is_integer(id) ->
        {:keyset, {mass, id}}

      _ ->
        {:offset, 0}
    end
  rescue
    ArgumentError -> {:offset, 0}
  end

  defp offset({:offset, value}) when is_integer(value), do: value
  defp offset(_cursor), do: 0

  defp cursor_fragment(%{fragment: fragment}), do: fragment
  defp cursor_fragment({first, _joined}), do: cursor_fragment(first)
  defp cursor_fragment({first, _one, _two}), do: cursor_fragment(first)
  defp cursor_fragment({first, _one, _two, _three}), do: cursor_fragment(first)
  defp cursor_fragment(_hit), do: nil

  defp parse_limit(nil), do: 50
  defp parse_limit(n) when is_integer(n), do: min(n, 200)
  defp parse_limit(s) when is_binary(s), do: s |> String.to_integer() |> min(200)

  defp scope_opts(nil), do: []
  defp scope_opts(id) when is_integer(id), do: [package_id: id]

  defp scope_opts(id) when is_binary(id) do
    case Integer.parse(id) do
      {int, ""} -> [package_id: int]
      _ -> []
    end
  end

  defp serialize_result(%module{} = entity)
       when module in [Exograph.Package, Exograph.PackageVersion, Exograph.FileRef] do
    JSONCodec.dump(entity)
  end

  defp serialize_result(hit) do
    r = SearchResult.from(hit)

    %{
      type: r.type,
      file: r.file,
      package: r.package,
      package_version: r.package_version,
      module: r.module,
      kind: r.kind,
      name: r.name,
      arity: r.arity,
      line: r.line,
      joined: r.joined_label
    }
  end
end
