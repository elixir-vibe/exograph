defmodule Exograph.Hex.StageTimings do
  @moduledoc false

  @table __MODULE__

  def reset do
    ensure_table!()
    :ets.delete_all_objects(@table)
  end

  def measure(stage, fun) when is_atom(stage) and is_function(fun, 0) do
    ensure_table!()
    started = System.monotonic_time(:microsecond)

    try do
      fun.()
    after
      :ets.insert(@table, {:duration, stage, System.monotonic_time(:microsecond) - started})
    end
  end

  def count(stage), do: count(stage, 1)

  def count(stage, amount) when is_atom(stage) and is_integer(amount) do
    ensure_table!()
    :ets.insert(@table, {:counter, stage, amount})
  end

  def snapshot do
    ensure_table!()

    @table
    |> :ets.tab2list()
    |> Enum.group_by(&snapshot_key/1, &snapshot_value/1)
    |> Map.new(fn
      {{:duration, stage}, durations} ->
        total_us = Enum.sum(durations)
        count = length(durations)

        {stage,
         %{
           count: count,
           total_ms: div(total_us, 1_000),
           avg_ms: div(total_us, max(count, 1) * 1_000),
           max_ms: div(Enum.max(durations, fn -> 0 end), 1_000)
         }}

      {{:counter, stage}, amounts} ->
        count = length(amounts)
        total = Enum.sum(amounts)

        {stage,
         %{
           count: count,
           total: total,
           avg: div(total, max(count, 1)),
           max: Enum.max(amounts, fn -> 0 end)
         }}
    end)
  end

  defp snapshot_key({kind, stage, _value}), do: {kind, stage}
  defp snapshot_key({stage, _duration_us}), do: {:duration, stage}

  defp snapshot_value({_kind, _stage, value}), do: value
  defp snapshot_value({_stage, duration_us}), do: duration_us

  defp ensure_table! do
    case :ets.whereis(@table) do
      :undefined ->
        :ets.new(@table, [:named_table, :public, :bag, {:write_concurrency, true}])

      _table ->
        :ok
    end
  end
end
