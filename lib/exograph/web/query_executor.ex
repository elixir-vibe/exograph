defmodule Exograph.Web.QueryExecutor do
  @moduledoc false

  alias Exograph.ShardedIndex
  alias Exograph.Web.SafeEval

  @default_limit 100
  @slow_query_ms 1_000.0

  def default_limit, do: @default_limit

  def execute(index, query, opts \\ [])

  def execute(index, %Exograph.Query{} = query, opts) do
    limit = Keyword.get(opts, :limit, @default_limit)
    skip = Keyword.get(opts, :skip, 0)
    cursor = Keyword.get(opts, :cursor)

    query_opts =
      Keyword.merge(Keyword.drop(opts, [:mode]), limit: limit, skip: skip)
      |> Keyword.put(:cursor, cursor)

    {elapsed_us, result} = :timer.tc(fn -> run_parsed(index, query, query_opts) end)
    format_result(index, result, elapsed_us)
  end

  def execute(index, query_string, opts) when is_binary(query_string) do
    mode = Keyword.get(opts, :mode, "structural")
    limit = Keyword.get(opts, :limit, @default_limit)
    skip = Keyword.get(opts, :skip, 0)
    cursor = Keyword.get(opts, :cursor)

    query_opts =
      Keyword.merge(Keyword.drop(opts, [:mode]), limit: limit, skip: skip)
      |> Keyword.put(:cursor, cursor)

    {elapsed_us, result} =
      :timer.tc(fn ->
        case mode do
          "text" ->
            {:ok, results} = Exograph.search_text(index, query_string, query_opts)
            {:ok, results, limit, nil}

          _ ->
            case SafeEval.eval(query_string) do
              {:ok, parsed} -> run_parsed(index, parsed, query_opts)
              {:error, _} = error -> error
            end
        end
      end)

    format_result(index, result, elapsed_us)
  end

  defp format_result(index, result, elapsed_us) do
    elapsed_ms = Float.round(elapsed_us / 1000, 1)

    case result do
      {:ok, results, effective_limit, total} ->
        {:ok, results, elapsed_ms, effective_limit, total,
         meta(index, results, elapsed_ms, effective_limit, total)}

      {:error, error} ->
        {:error, error}
    end
  end

  defp run_parsed(index, %Exograph.Query{} = query, opts) do
    default_limit = Keyword.fetch!(opts, :limit)
    effective_limit = query.limit || default_limit
    query_opts = Keyword.put(opts, :limit, effective_limit)

    with {:ok, results} <- Exograph.all(index, query, query_opts) do
      {:ok, results, effective_limit, nil}
    end
  end

  defp run_parsed(index, pattern, opts) when is_binary(pattern) do
    limit = Keyword.fetch!(opts, :limit)

    case Exograph.search(index, pattern, opts) do
      {:ok, results} -> {:ok, results, limit, nil}
      error -> error
    end
  end

  defp meta(index, results, elapsed_ms, limit, total) do
    returned = length(results)
    total_relation = total_relation(returned, limit, total)

    %{
      limit: limit,
      returned: returned,
      timed_out: false,
      partial: false,
      shards: shard_meta(index),
      total: total_payload(total, returned, total_relation),
      notices: notices(elapsed_ms, returned, limit, total_relation)
    }
  end

  defp shard_meta(%ShardedIndex{shards: shards}) do
    total = length(shards)
    %{total: total, successful: total, failed: 0}
  end

  defp shard_meta(_index), do: %{total: 1, successful: 1, failed: 0}

  defp total_relation(_returned, _limit, total) when is_integer(total), do: "eq"
  defp total_relation(returned, limit, _total) when returned >= limit, do: "gte"
  defp total_relation(_returned, _limit, _total), do: "eq"

  defp total_payload(total, _returned, "eq") when is_integer(total),
    do: %{value: total, relation: "eq"}

  defp total_payload(_total, returned, relation), do: %{value: returned, relation: relation}

  defp notices(elapsed_ms, returned, _limit, _total_relation) do
    []
    |> maybe_notice(elapsed_ms >= @slow_query_ms, %{
      kind: :slow_query,
      message:
        "Query took #{elapsed_ms}ms for #{returned} returned results. Narrower filters usually make structural search faster and more useful."
    })
    |> Enum.reverse()
  end

  defp maybe_notice(notices, true, notice), do: [notice | notices]
  defp maybe_notice(notices, false, _notice), do: notices
end
