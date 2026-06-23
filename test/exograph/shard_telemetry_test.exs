defmodule Exograph.ShardTelemetryTest do
  use ExUnit.Case, async: true

  alias Exograph.ShardTelemetry

  test "emits shard query stop telemetry" do
    handler_id = {__MODULE__, self(), make_ref()}

    :telemetry.attach(
      handler_id,
      [:exograph, :shard, :query, :stop],
      &__MODULE__.handle_event/4,
      self()
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    ShardTelemetry.record(:all, %{id: 1, prefix: "hex_1"}, 12.3, {:ok, [:hit]})

    assert_receive {:shard_query_stop, [:exograph, :shard, :query, :stop], measurements, metadata}

    assert measurements.duration_ms == 12.3
    assert measurements.returned == 1
    assert metadata.function == :all
    assert metadata.shard_id == 1
    assert metadata.shard_prefix == "hex_1"
    assert metadata.status == :ok
  end

  def handle_event(event, measurements, metadata, test_pid) do
    send(test_pid, {:shard_query_stop, event, measurements, metadata})
  end
end
