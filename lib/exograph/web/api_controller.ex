defmodule Exograph.Web.APIController do
  @moduledoc false
  use Phoenix.Controller, formats: [:json]

  import Ecto.Query

  alias Exograph.ShardedIndex

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
    skip = decode_cursor(params["cursor"])
    package_id = params["package_id"]

    opts = [limit: limit, skip: skip, timeout: @search_timeout_ms] ++ scope_opts(package_id)

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
        next_cursor = if length(hits) == limit, do: encode_cursor(skip + limit), else: nil

        payload = %{
          results: Enum.map(hits, &serialize_result/1),
          count: length(hits),
          elapsed_ms: elapsed_ms,
          next_cursor: next_cursor
        }

        json(conn, maybe_put_meta(payload, meta))

      {:error, reason} ->
        conn |> put_status(400) |> json(%{error: error_payload(reason)})
    end
  end

  def query(conn, params) do
    index = index()
    query_string = params["query"] || ""
    skip = decode_cursor(params["cursor"])

    {elapsed_us, result} =
      :timer.tc(fn -> QueryExecutor.execute(index, query_string, skip: skip) end)

    case result do
      {:ok, hits, elapsed_ms, effective_limit, _total, meta} ->
        QueryTelemetry.record("dsl", query_string, elapsed_ms, :ok, length(hits), %{
          endpoint: "/api/query"
        })

        next_cursor =
          if length(hits) >= effective_limit, do: encode_cursor(skip + effective_limit), else: nil

        json(conn, %{
          results: Enum.map(hits, &serialize_result/1),
          count: length(hits),
          elapsed_ms: elapsed_ms,
          next_cursor: next_cursor,
          meta: meta
        })

      {:error, message} ->
        QueryTelemetry.record(
          "dsl",
          query_string,
          Float.round(elapsed_us / 1000, 1),
          :error,
          0,
          %{
            endpoint: "/api/query"
          }
        )

        conn |> put_status(400) |> json(%{error: message})
    end
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

    case Code.string_to_quoted(pattern) do
      {:ok, {kind, _meta, [{binding, _, nil}, ast_pattern]}}
      when kind in [:matches, :contains] and is_atom(binding) ->
        pattern = if is_binary(ast_pattern), do: ast_pattern, else: Macro.to_string(ast_pattern)

        ~s|from(#{binding} in Fragment, where: #{kind}(#{binding}, #{inspect(pattern)}), limit: #{limit})|

      {:ok, _other} ->
        pattern

      {:error, _reason} ->
        pattern
    end
  end

  defp error_payload(%{} = reason), do: reason
  defp error_payload(reason), do: to_string(reason)

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
        %{id: first.id, name: first.name, fragments: Enum.sum(Enum.map(rows, & &1.fragments))}
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

    counts =
      Map.new(@stats_tables, fn table ->
        {Atom.to_string(table),
         repo.aggregate(Schema.source(table, prefix), :count, timeout: 30_000)}
      end)

    counts
  end

  defp shard_index(%{index: index}), do: index
  defp shard_index(index), do: index

  defp encode_cursor(offset) when is_integer(offset),
    do: Base.url_encode64("#{offset}", padding: false)

  defp decode_cursor(nil), do: 0
  defp decode_cursor(""), do: 0

  defp decode_cursor(encoded) do
    with {:ok, decoded} <- Base.url_decode64(encoded, padding: false),
         {offset, ""} <- Integer.parse(decoded) do
      offset
    else
      _ -> 0
    end
  end

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
