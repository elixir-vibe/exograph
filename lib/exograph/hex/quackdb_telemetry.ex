defmodule Exograph.Hex.QuackDBTelemetry do
  @moduledoc false

  alias Exograph.Hex.StageTimings

  @events [
    [:quackdb, :append, :start],
    [:quackdb, :append, :stop],
    [:quackdb, :query, :stop],
    [:quackdb, :fetch, :stop]
  ]

  def attach(false), do: nil

  def attach(true) do
    id = "exograph-hex-quackdb-#{System.unique_integer([:positive])}"
    {:ok, agent} = Agent.start_link(fn -> %{append_context: %{}} end)

    :telemetry.attach_many(id, @events, &__MODULE__.handle_event/4, agent)
    {id, agent}
  end

  def detach(nil), do: :ok

  def detach({id, agent}) do
    :telemetry.detach(id)
    Agent.stop(agent)
    :ok
  end

  def handle_event([:quackdb, :append, :start], _measurements, metadata, agent) do
    Agent.update(agent, fn state ->
      case Map.get(metadata, :telemetry_span_context) do
        nil ->
          state

        context ->
          put_in(state, [:append_context, context], append_source(metadata))
      end
    end)
  end

  def handle_event([:quackdb, :append, :stop], measurements, metadata, agent) do
    source =
      Agent.get_and_update(agent, fn state ->
        context = Map.get(metadata, :telemetry_span_context)
        {source, contexts} = Map.pop(state.append_context, context, append_source(metadata))
        {source, %{state | append_context: contexts}}
      end)

    suffix = append_suffix(source)

    count(metric(:calls, suffix))
    count(metric(:rows, suffix), Map.get(metadata, :rows, 0))
    count(metric(:batches, suffix), Map.get(metadata, :batches, 0))
    count(metric(:request_bytes, suffix), Map.get(metadata, :request_bytes, 0))
    count(metric(:response_bytes, suffix), Map.get(metadata, :response_bytes, 0))
    count_native(metric(:duration_us, suffix), Map.get(measurements, :duration, 0))
    count_native(metric(:append_duration_us, suffix), Map.get(metadata, :append_duration, 0))
    count_native(metric(:encode_duration_us, suffix), Map.get(metadata, :encode_duration, 0))

    count_native(
      metric(:transport_duration_us, suffix),
      Map.get(metadata, :transport_duration, 0)
    )

    count_native(metric(:decode_duration_us, suffix), Map.get(metadata, :decode_duration, 0))
  end

  def handle_event([:quackdb, :query, :stop], measurements, metadata, _agent) do
    command = query_command(metadata)
    count(metric(:query_calls, command))
    count(metric(:query_rows, command), Map.get(metadata, :rows, 0))
    count_native(metric(:query_duration_us, command), Map.get(measurements, :duration, 0))
  end

  def handle_event([:quackdb, :fetch, :stop], measurements, metadata, _agent) do
    count(:quackdb_fetch_calls)
    count(:quackdb_fetch_chunks, Map.get(metadata, :chunks, 0))
    count_native(:quackdb_fetch_duration_us, Map.get(measurements, :duration, 0))
  end

  def handle_event(_event, _measurements, _metadata, _agent), do: :ok

  defp append_source(metadata) do
    schema = Map.get(metadata, :schema, "")
    table = Map.get(metadata, :table, "unknown")

    if schema in [nil, ""] do
      to_string(table)
    else
      to_string(schema) <> "." <> to_string(table)
    end
  end

  defp append_suffix(source) do
    source
    |> String.split(".")
    |> List.last()
    |> normalize_table()
    |> source_suffix()
  end

  defp normalize_table("exograph_fragment_merge_" <> _suffix), do: "fragment_merge_stage"
  defp normalize_table(table), do: table

  defp source_suffix("fragment_merge_stage"), do: :fragment_merge_stage

  defp source_suffix(source) do
    source
    |> String.split("_")
    |> Enum.reverse()
    |> case do
      ["edges", "call" | _] -> :call_edges
      ["nodes", "graph" | _] -> :graph_nodes
      ["terms", "fragment" | _] -> :fragment_terms
      ["versions", "package" | _] -> :package_versions
      [suffix | _] -> known_suffix(suffix)
      [] -> :other
    end
  end

  defp known_suffix("comments"), do: :comments
  defp known_suffix("definitions"), do: :definitions
  defp known_suffix("files"), do: :files
  defp known_suffix("fragments"), do: :fragments
  defp known_suffix("packages"), do: :packages
  defp known_suffix("references"), do: :references
  defp known_suffix("terms"), do: :terms
  defp known_suffix(_suffix), do: :other

  defp query_command(%{command: command}) when is_atom(command), do: command
  defp query_command(_metadata), do: :unknown

  defp metric(kind, suffix), do: String.to_atom("quackdb_#{kind}_#{suffix}")

  defp count(metric, amount \\ 1)
  defp count(_metric, 0), do: :ok
  defp count(metric, amount), do: StageTimings.count(metric, amount)

  defp count_native(metric, native) when is_integer(native) and native > 0 do
    StageTimings.count(metric, System.convert_time_unit(native, :native, :microsecond))
  end

  defp count_native(_metric, _native), do: :ok
end
