defmodule Exograph.Hex.BroadwayPipeline do
  @moduledoc false

  use Broadway

  alias Broadway.Message
  alias Exograph.Hex.Progress

  @behaviour Broadway.Acknowledger

  def index(entries, opts) do
    name = Keyword.get(opts, :name, unique_name())
    owner = self()
    total = length(entries)
    started = System.monotonic_time(:millisecond)
    telemetry_id = Exograph.Hex.BroadwayTelemetry.attach(name)

    {:ok, pid} =
      Broadway.start_link(__MODULE__,
        name: name,
        context: %{opts: opts, shards: nil},
        producer: producer(Enum.with_index(entries), owner),
        processors: processors(opts),
        batchers: [default: batcher(opts)]
      )

    finish(name, pid, total, started, telemetry_id)
  end

  def index_sharded(shards, opts) do
    name = Keyword.get(opts, :name, unique_name())
    owner = self()

    jobs = interleave_shard_jobs(shards)

    shard_by_id = Map.new(shards, &{&1.id, &1})
    batchers = [shards: Keyword.merge(batcher(opts), concurrency: length(shards))]
    started = System.monotonic_time(:millisecond)
    telemetry_id = Exograph.Hex.BroadwayTelemetry.attach(name)

    {:ok, pid} =
      Broadway.start_link(__MODULE__,
        name: name,
        context: %{opts: opts, shards: shard_by_id},
        producer: producer(jobs, owner),
        processors: processors(opts),
        batchers: batchers
      )

    finish(name, pid, length(jobs), started, telemetry_id)
  end

  def transform(data, [%{owner: owner}]) do
    %Message{data: normalize_job(data), acknowledger: {__MODULE__, owner, nil}}
  end

  @impl Broadway
  def handle_message(_, message, %{shards: nil}) do
    message
  end

  def handle_message(_, message, %{shards: shards}) when is_map(shards) do
    message
    |> Message.put_batcher(:shards)
    |> Message.put_batch_key(message.data.shard_id)
  end

  @impl Broadway
  def handle_batch(_batcher, messages, _batch_info, %{opts: opts, shards: nil}) do
    Enum.map(messages, &index_message(&1, opts))
  end

  def handle_batch(:shards, messages, batch_info, %{opts: opts, shards: shards}) do
    shard_id = batch_info.batch_key
    shard = Map.fetch!(shards, shard_id)

    Exograph.DuckDBShards.with_repo(shard, fn ->
      shard_opts =
        opts
        |> Keyword.put(:repo, shard.repo)
        |> Keyword.put(:dynamic_repo, shard.dynamic_repo)
        |> Keyword.put(:prefix, shard.prefix)

      Enum.map(messages, &index_message(&1, shard_opts))
    end)
  end

  @impl Broadway
  def handle_failed(messages, _context), do: messages

  @impl Broadway.Acknowledger
  def ack(owner, successful, failed) do
    send(
      owner,
      {:hex_broadway_ack, Enum.map(successful, & &1.data), Enum.map(failed, &failed_data/1)}
    )

    :ok
  end

  defp failed_data(%Message{data: data, status: {:failed, reason}}) do
    Map.put_new(data, :result, {:error, {:broadway_failed, reason}})
  end

  defp failed_data(%Message{data: data, status: {kind, reason, stacktrace}})
       when kind in [:throw, :error, :exit] do
    Map.put_new(data, :result, {:error, {:broadway_failed, kind, reason, stacktrace}})
  end

  defp failed_data(%Message{data: data, status: status}) do
    Map.put_new(data, :result, {:error, {:broadway_failed, status}})
  end

  defp producer(entries, owner) do
    [
      module: {Exograph.Hex.BroadwayProducer, entries: entries},
      transformer: {__MODULE__, :transform, [%{owner: owner}]},
      concurrency: 1
    ]
  end

  defp processors(opts) do
    [
      default: [
        concurrency: Keyword.get(opts, :processor_concurrency, 1),
        max_demand: Keyword.get(opts, :processor_max_demand, 1)
      ]
    ]
  end

  defp batcher(opts) do
    [
      concurrency: 1,
      batch_size: Keyword.get(opts, :batch_size, 1),
      batch_timeout: Keyword.get(opts, :batch_timeout, 100)
    ]
  end

  defp index_message(message, opts) do
    %{entry: entry, index: index} = message.data
    Progress.package_started(entry)

    result = index_with_retries(entry, index, opts)
    Progress.package_done(entry, result)

    Message.update_data(message, &Map.put(&1, :result, result))
  rescue
    error ->
      result = {:error, Exception.message(error)}
      Progress.package_done(message.data.entry, result)
      Message.update_data(message, &Map.put(&1, :result, result))
  end

  defp index_with_retries(entry, index, opts) do
    retry_count = Keyword.get(opts, :retry_count, 3)
    retry_sleep = Keyword.get(opts, :retry_sleep, 1_000)
    index_fun = Keyword.get(opts, :index_fun, &Exograph.Hex.Corpus.index_entry/3)
    sleep_fun = Keyword.get(opts, :sleep_fun, &Process.sleep/1)

    Enum.reduce_while(0..retry_count, nil, fn attempt, _last_result ->
      result = safe_index_entry(index_fun, entry, index, opts)

      if transient_error?(result) and attempt < retry_count do
        sleep_fun.(retry_sleep * (attempt + 1))
        {:cont, result}
      else
        {:halt, result}
      end
    end)
  end

  defp safe_index_entry(index_fun, entry, index, opts) do
    index_fun.(entry, index, opts)
  rescue
    error -> {:error, {error.__struct__, Exception.message(error)}}
  catch
    :exit, reason -> {:error, {:exit, reason}}
    kind, reason -> {:error, {kind, reason}}
  end

  defp transient_error?({:error, reason}) do
    reason
    |> inspect()
    |> String.downcase()
    |> String.contains?([
      "queue_timeout",
      "connection not available",
      "request was dropped from queue",
      "timed out",
      "time out",
      "timeout",
      "transport_error"
    ])
  end

  defp transient_error?(_result), do: false

  defp finish(name, pid, total, started, telemetry_id) do
    results = await_results(total, %{ok: 0, skipped: 0, error: 0, failures: []})
    Exograph.Hex.BroadwayTelemetry.detach(telemetry_id)
    Broadway.stop(name)
    ref = Process.monitor(pid)

    receive do
      {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
    after
      5_000 -> Process.demonitor(ref, [:flush])
    end

    {results, System.monotonic_time(:millisecond) - started}
  end

  defp await_results(0, acc), do: %{acc | failures: Enum.reverse(acc.failures)}

  defp await_results(remaining, acc) do
    receive do
      {:hex_broadway_ack, successful, failed} ->
        messages = successful ++ failed

        next =
          Enum.reduce(messages, acc, fn
            %{result: :ok}, acc ->
              %{acc | ok: acc.ok + 1}

            %{result: :skipped}, acc ->
              %{acc | skipped: acc.skipped + 1}

            %{entry: entry, result: {:error, reason}}, acc ->
              %{acc | error: acc.error + 1, failures: [failure(entry, reason) | acc.failures]}

            %{entry: entry}, acc ->
              %{acc | error: acc.error + 1, failures: [failure(entry, :unknown) | acc.failures]}
          end)

        await_results(remaining - length(messages), next)
    end
  end

  defp failure(entry, reason) do
    %{name: entry.name, version: entry.version, reason: inspect(reason, limit: 50)}
  end

  defp normalize_job({entry, index}), do: %{entry: entry, index: index}
  defp normalize_job(%{entry: _entry, index: _index} = job), do: job

  defp interleave_shard_jobs(shards) do
    indexed_entries =
      Map.new(shards, fn shard ->
        jobs =
          Enum.with_index(shard.entries, fn entry, index ->
            %{entry: entry, index: index, shard_id: shard.id}
          end)

        {shard.id, jobs}
      end)

    max_count =
      indexed_entries
      |> Map.values()
      |> Enum.map(&length/1)
      |> Enum.max(fn -> 0 end)

    for index <- 0..max(max_count - 1, 0),
        shard <- shards,
        job = Enum.at(Map.fetch!(indexed_entries, shard.id), index),
        not is_nil(job) do
      job
    end
  end

  defp unique_name do
    :erlang.unique_integer([:positive])
    |> then(&Module.concat(__MODULE__, "Pipeline#{&1}"))
  end
end
