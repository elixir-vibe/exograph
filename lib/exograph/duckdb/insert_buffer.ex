defmodule Exograph.DuckDB.InsertBuffer do
  @moduledoc false

  use GenServer

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  def insert(_buffer, _source, []), do: :ok
  def insert(nil, _source, _entries), do: :ok

  def insert(buffer, source, entries) when is_pid(buffer) do
    entries = List.wrap(entries)
    Exograph.Hex.StageTimings.count(metric(source, :enqueue_rows), length(entries))
    GenServer.call(buffer, {:insert, source, entries}, :infinity)
  end

  def flush(nil), do: :ok

  def flush(buffer) when is_pid(buffer) do
    GenServer.call(buffer, :flush, :infinity)
  end

  def stop(nil), do: :ok

  def stop(buffer) when is_pid(buffer) do
    GenServer.stop(buffer, :normal, :infinity)
  end

  @impl true
  def init(opts) do
    {:ok,
     %{
       repo: Keyword.fetch!(opts, :repo),
       dynamic_repo: Keyword.get(opts, :dynamic_repo),
       chunk_size: Keyword.get(opts, :chunk_size, 50_000),
       buffers: %{},
       counts: %{}
     }}
  end

  @impl true
  def handle_call({:insert, source, entries}, _from, state) do
    entries = List.wrap(entries)
    batches = Map.get(state.buffers, source, [])
    count = Map.get(state.counts, source, 0) + length(entries)

    state = %{
      state
      | buffers: Map.put(state.buffers, source, [entries | batches]),
        counts: Map.put(state.counts, source, count)
    }

    state = if count >= state.chunk_size, do: flush_source(state, source), else: state
    {:reply, :ok, state}
  end

  @impl true
  def handle_call(:flush, _from, state) do
    {:reply, :ok, flush_all(state)}
  end

  @impl true
  def terminate(_reason, state) do
    flush_all(state)
    :ok
  end

  defp flush_all(state) do
    state.buffers
    |> Map.keys()
    |> Enum.reduce(state, &flush_source(&2, &1))
  end

  defp flush_source(state, source) do
    entries =
      state.buffers
      |> Map.get(source, [])
      |> Enum.reverse()
      |> Enum.flat_map(& &1)

    if entries != [] do
      flush_entries(state, source, entries)
    end

    %{
      state
      | buffers: Map.delete(state.buffers, source),
        counts: Map.delete(state.counts, source)
    }
  end

  defp flush_entries(state, source, entries) do
    Exograph.Hex.StageTimings.count(metric(source, :flush_rows), length(entries))

    Exograph.Hex.StageTimings.measure(metric(source, :flush), fn ->
      with_dynamic_repo(state, fn ->
        state.repo.insert_all(source, entries,
          insert_method: :append,
          chunk_every: 10_000,
          timeout: :infinity
        )
      end)
    end)
  end

  defp metric(source, kind) do
    case source_suffix(source) do
      "comments" -> metric_atom(kind, :comments)
      "definitions" -> metric_atom(kind, :definitions)
      "references" -> metric_atom(kind, :references)
      "graph_nodes" -> metric_atom(kind, :graph_nodes)
      "call_edges" -> metric_atom(kind, :call_edges)
      _other -> metric_atom(kind, :other)
    end
  end

  defp metric_atom(:enqueue_rows, suffix), do: :"duckdb_insert_buffer_enqueue_#{suffix}_rows"
  defp metric_atom(:flush_rows, suffix), do: :"duckdb_insert_buffer_flush_#{suffix}_rows"
  defp metric_atom(:flush, suffix), do: :"duckdb_insert_buffer_flush_#{suffix}"

  defp source_suffix({table, _schema}), do: source_suffix(table)

  defp source_suffix(source) when is_binary(source) do
    source
    |> String.split("_")
    |> Enum.reverse()
    |> case do
      ["edges", "call" | _] -> "call_edges"
      ["nodes", "graph" | _] -> "graph_nodes"
      [suffix | _] -> suffix
      [] -> source
    end
  end

  defp with_dynamic_repo(%{dynamic_repo: nil}, fun), do: fun.()

  defp with_dynamic_repo(%{repo: repo, dynamic_repo: dynamic_repo}, fun) do
    if function_exported?(repo, :put_dynamic_repo, 1) and
         function_exported?(repo, :get_dynamic_repo, 0) do
      previous = repo.get_dynamic_repo()
      repo.put_dynamic_repo(dynamic_repo)

      try do
        fun.()
      after
        repo.put_dynamic_repo(previous)
      end
    else
      fun.()
    end
  end
end
