defmodule ExographStageTimingsTest do
  use ExUnit.Case, async: false

  alias Exograph.Hex.StageTimings

  test "snapshot includes duration and counter metrics" do
    StageTimings.reset()

    StageTimings.measure(:work, fn -> :ok end)
    StageTimings.count(:rows, 2)
    StageTimings.count(:rows, 3)

    snapshot = StageTimings.snapshot()

    assert %{count: 1, total_ms: total_ms, avg_ms: avg_ms, max_ms: max_ms} = snapshot.work
    assert is_integer(total_ms)
    assert is_integer(avg_ms)
    assert is_integer(max_ms)

    assert snapshot.rows == %{count: 2, total: 5, avg: 2, max: 3}
  end
end
