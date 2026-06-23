defmodule Exograph.Web.QueryTelemetryTest do
  use ExUnit.Case, async: true

  alias Exograph.Web.QueryTelemetry

  test "emits query stop telemetry" do
    handler_id = {__MODULE__, self(), make_ref()}

    :telemetry.attach(
      handler_id,
      [:exograph, :web, :query, :stop],
      &__MODULE__.handle_event/4,
      self()
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    QueryTelemetry.record("text", "defmodule", 12.3, :ok, 2, %{endpoint: "/api/search"})

    assert_receive {:query_stop, [:exograph, :web, :query, :stop], measurements, metadata}
    assert measurements.duration_ms == 12.3
    assert measurements.returned == 2
    assert metadata.kind == "text"
    assert metadata.query == "defmodule"
    assert metadata.status == :ok
    assert metadata.endpoint == "/api/search"
  end

  def handle_event(event, measurements, metadata, test_pid) do
    send(test_pid, {:query_stop, event, measurements, metadata})
  end
end
