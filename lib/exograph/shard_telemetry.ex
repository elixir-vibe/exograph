defmodule Exograph.ShardTelemetry do
  @moduledoc """
  Emits telemetry for work performed by a single shard in sharded searches.

  The event name is `[:exograph, :shard, :query, :stop]`. Measurements include
  `:duration_ms` and `:returned`; metadata includes the fanout function, shard
  identity, status, and error reason when available.
  """

  require Logger

  @event [:exograph, :shard, :query, :stop]
  @default_slow_query_ms 1_000.0

  @doc """
  Records one completed shard query.
  """
  def record(function, shard, duration_ms, result) do
    measurements = %{
      duration_ms: duration_ms,
      returned: returned(result)
    }

    metadata = %{
      function: function,
      shard_id: shard_value(shard, :id),
      shard_prefix: shard_value(shard, :prefix),
      status: status(result),
      reason: reason(result)
    }

    :telemetry.execute(@event, measurements, metadata)
    maybe_log_slow_shard(measurements, metadata)
    :ok
  end

  defp maybe_log_slow_shard(%{duration_ms: duration_ms, returned: returned}, metadata) do
    if duration_ms >= slow_query_ms() do
      Logger.warning(fn ->
        "slow exograph shard query function=#{metadata.function} " <>
          "shard_id=#{inspect(metadata.shard_id)} shard_prefix=#{inspect(metadata.shard_prefix)} " <>
          "status=#{metadata.status} duration_ms=#{duration_ms} returned=#{returned}"
      end)
    end
  end

  defp slow_query_ms do
    Application.get_env(:exograph, :slow_shard_query_ms, @default_slow_query_ms)
  end

  defp returned({:ok, hits}) when is_list(hits), do: length(hits)
  defp returned({:ok, count}) when is_integer(count), do: count
  defp returned(_result), do: 0

  defp status({:ok, _result}), do: :ok
  defp status(:unknown), do: :unknown
  defp status({:error, _reason}), do: :error
  defp status(_result), do: :error

  defp reason({:error, reason}), do: inspect(reason)
  defp reason(_result), do: nil

  defp shard_value(shard, key) when is_map(shard), do: Map.get(shard, key)
  defp shard_value(_shard, _key), do: nil
end
