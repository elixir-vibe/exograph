defmodule Exograph.Web.QueryTelemetry do
  @moduledoc """
  Emits telemetry and slow-query logs for public web search requests.

  The event name is `[:exograph, :web, :query, :stop]`. Measurements include
  `:duration_ms` and `:returned`; metadata includes query kind, status, a
  truncated query string, and endpoint/source details supplied by callers.
  """

  require Logger

  @event [:exograph, :web, :query, :stop]
  @default_slow_query_ms 1_000.0
  @max_query_length 240

  @doc """
  Records a completed query.
  """
  def record(kind, query, duration_ms, status, returned, metadata \\ %{}) do
    metadata =
      metadata
      |> Map.merge(%{
        kind: normalize_kind(kind),
        query: truncate(to_string(query || "")),
        status: status
      })

    measurements = %{
      duration_ms: duration_ms,
      returned: returned || 0
    }

    :telemetry.execute(@event, measurements, metadata)
    maybe_log_slow_query(measurements, metadata)
    :ok
  end

  defp maybe_log_slow_query(%{duration_ms: duration_ms, returned: returned}, metadata) do
    if duration_ms >= slow_query_ms() do
      Logger.warning(fn ->
        "slow exograph query endpoint=#{metadata[:endpoint]} kind=#{metadata.kind} " <>
          "status=#{metadata.status} duration_ms=#{duration_ms} returned=#{returned} " <>
          "query=#{inspect(metadata.query)}"
      end)
    end
  end

  defp slow_query_ms do
    Application.get_env(:exograph, :slow_query_ms, @default_slow_query_ms)
  end

  defp normalize_kind(kind) when is_atom(kind), do: Atom.to_string(kind)
  defp normalize_kind(kind) when is_binary(kind), do: kind
  defp normalize_kind(kind), do: inspect(kind)

  defp truncate(query) when byte_size(query) <= @max_query_length, do: query

  defp truncate(query) do
    binary_part(query, 0, @max_query_length) <> "…"
  end
end
