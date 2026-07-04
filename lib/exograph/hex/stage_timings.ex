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
      duration_us = System.monotonic_time(:microsecond) - started
      update({:duration, stage}, duration_us)
    end
  end

  def count(stage), do: count(stage, 1)

  def count(stage, amount) when is_atom(stage) and is_integer(amount) do
    ensure_table!()
    update({:counter, stage}, amount)
  end

  def snapshot do
    ensure_table!()

    @table
    |> :ets.tab2list()
    |> Map.new(fn
      {{:duration, stage}, count, total_us, max_us} ->
        {stage,
         %{
           count: count,
           total_ms: div(total_us, 1_000),
           avg_ms: div(total_us, max(count, 1) * 1_000),
           max_ms: div(max_us, 1_000)
         }}

      {{:counter, stage}, count, total, max} ->
        {stage,
         %{
           count: count,
           total: total,
           avg: div(total, max(count, 1)),
           max: max
         }}
    end)
  end

  defp update(key, value) do
    case :ets.lookup(@table, key) do
      [] ->
        :ets.insert(@table, {key, 1, value, value})

      [{^key, count, total, max}] ->
        :ets.insert(@table, {key, count + 1, total + value, max(max, value)})
    end
  end

  defp ensure_table! do
    case :ets.whereis(@table) do
      :undefined ->
        :ets.new(@table, [:named_table, :public, :set, {:write_concurrency, true}])

      _table ->
        :ok
    end
  end
end
