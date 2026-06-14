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
      :ets.insert(@table, {stage, System.monotonic_time(:microsecond) - started})
    end
  end

  def count(stage) when is_atom(stage) do
    ensure_table!()
    :ets.insert(@table, {stage, 0})
  end

  def snapshot do
    ensure_table!()

    @table
    |> :ets.tab2list()
    |> Enum.group_by(fn {stage, _duration_us} -> stage end, fn {_stage, duration_us} ->
      duration_us
    end)
    |> Map.new(fn {stage, durations} ->
      total_us = Enum.sum(durations)
      count = length(durations)

      {stage,
       %{
         count: count,
         total_ms: div(total_us, 1_000),
         avg_ms: div(total_us, max(count, 1) * 1_000),
         max_ms: div(Enum.max(durations, fn -> 0 end), 1_000)
       }}
    end)
  end

  defp ensure_table! do
    case :ets.whereis(@table) do
      :undefined ->
        :ets.new(@table, [:named_table, :public, :bag, {:write_concurrency, true}])

      _table ->
        :ok
    end
  end
end
