defmodule Exograph.Hex.BroadwayPipelineTest do
  use ExUnit.Case, async: true

  alias Broadway.Message
  alias Exograph.Hex.BroadwayPipeline

  test "retries transient time out results" do
    {:ok, attempts} = Agent.start_link(fn -> 0 end)

    index_fun = fn _entry, _index, _opts ->
      attempt = Agent.get_and_update(attempts, &{&1 + 1, &1 + 1})
      if attempt < 3, do: {:error, "commit time out"}, else: :ok
    end

    {result, _elapsed_ms} =
      BroadwayPipeline.index([%{name: "pkg", version: "1.0.0"}],
        name: :"test_broadway_retry_#{System.unique_integer([:positive])}",
        index_fun: index_fun,
        sleep_fun: fn _ms -> :ok end,
        retry_count: 3,
        retry_sleep: 0
      )

    assert result.ok == 1
    assert result.error == 0
    assert Agent.get(attempts, & &1) == 3
  end

  test "retries transient raised exceptions" do
    {:ok, attempts} = Agent.start_link(fn -> 0 end)

    index_fun = fn _entry, _index, _opts ->
      attempt = Agent.get_and_update(attempts, &{&1 + 1, &1 + 1})
      if attempt < 2, do: raise("request was dropped from queue"), else: :ok
    end

    {result, _elapsed_ms} =
      BroadwayPipeline.index([%{name: "pkg", version: "1.0.0"}],
        name: :"test_broadway_exception_retry_#{System.unique_integer([:positive])}",
        index_fun: index_fun,
        sleep_fun: fn _ms -> :ok end,
        retry_count: 2,
        retry_sleep: 0
      )

    assert result.ok == 1
    assert result.error == 0
    assert Agent.get(attempts, & &1) == 2
  end

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
