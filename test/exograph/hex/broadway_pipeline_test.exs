defmodule Exograph.Hex.BroadwayPipelineTest do
  use ExUnit.Case, async: true

  alias Broadway.Message
  alias Exograph.Hex.BroadwayPipeline

  test "ack preserves failed message reasons" do
    owner = self()

    successful = [
      %Message{
        data: %{entry: %{name: "ok", version: "1.0.0"}, result: :ok},
        acknowledger: {BroadwayPipeline, owner, nil}
      }
    ]

    failed = [
      %Message{
        data: %{entry: %{name: "bad", version: "1.0.0"}},
        acknowledger: {BroadwayPipeline, owner, nil},
        status: {:failed, :commit_timeout}
      }
    ]

    assert :ok = BroadwayPipeline.ack(owner, successful, failed)

    assert_receive {:hex_broadway_ack, [ok], [bad]}
    assert ok.result == :ok
    assert bad.result == {:error, {:broadway_failed, :commit_timeout}}
  end
end
