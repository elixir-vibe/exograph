defmodule Exograph.DuckDB.InsertBuffer do
  @moduledoc false

  use GenServer

  alias Exograph.DuckDB.InsertBuffer.Worker

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  def insert(_buffer, _source, []), do: :ok
  def insert(nil, _source, _entries), do: :ok

  def insert(buffer, source, entries) when is_pid(buffer) do
    entries = List.wrap(entries)
    Exograph.Hex.StageTimings.count(metric(source, :enqueue_rows), length(entries))

    Exograph.Hex.StageTimings.measure(metric(source, :call), fn ->
      buffer
      |> worker_for(source)
      |> Worker.insert(entries)
    end)
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
       workers: %{}
     }}
  end

  @impl true
  def handle_call({:worker_for, source}, _from, state) do
    {worker, state} = get_or_start_worker(state, source)
    {:reply, worker, state}
  end

  def handle_call(:flush, _from, state) do
    flush_all(state)
    {:reply, :ok, state}
  end

  @impl true
  def terminate(_reason, state) do
    flush_all(state)
    stop_workers(state)
    :ok
  end

  def metric(source, kind) do
    case source_suffix(source) do
      "comments" -> metric_atom(kind, :comments)
      "definitions" -> metric_atom(kind, :definitions)
      "references" -> metric_atom(kind, :references)
      "graph_nodes" -> metric_atom(kind, :graph_nodes)
      "call_edges" -> metric_atom(kind, :call_edges)
      _other -> metric_atom(kind, :other)
    end
  end

  defp worker_for(buffer, source) do
    GenServer.call(buffer, {:worker_for, source}, :infinity)
  end

  defp get_or_start_worker(state, source) do
    case Map.fetch(state.workers, source) do
      {:ok, worker} when is_pid(worker) ->
        {worker, state}

      :error ->
        {:ok, worker} =
          Worker.start_link(
            repo: state.repo,
            dynamic_repo: state.dynamic_repo,
            chunk_size: state.chunk_size,
            source: source
          )

        {worker, %{state | workers: Map.put(state.workers, source, worker)}}
    end
  end

  defp flush_all(state) do
    state.workers
    |> Map.values()
    |> Enum.each(&Worker.flush/1)
  end

  defp stop_workers(state) do
    state.workers
    |> Map.values()
    |> Enum.each(fn worker ->
      if Process.alive?(worker) do
        GenServer.stop(worker, :normal, :infinity)
      end
    end)
  end

  defp metric_atom(:enqueue_rows, suffix), do: :"duckdb_insert_buffer_enqueue_#{suffix}_rows"
  defp metric_atom(:flush_rows, suffix), do: :"duckdb_insert_buffer_flush_#{suffix}_rows"
  defp metric_atom(:call, suffix), do: :"duckdb_insert_buffer_call_#{suffix}"
  defp metric_atom(:service, suffix), do: :"duckdb_insert_buffer_service_#{suffix}"
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
end

defmodule Exograph.DuckDB.InsertBuffer.Worker do
  @moduledoc false

  use GenServer

  alias Exograph.DuckDB.InsertBuffer

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  def insert(worker, entries) do
    GenServer.cast(worker, {:insert, entries})
  end

  def flush(worker) do
    GenServer.call(worker, :flush, :infinity)
  end

  @impl true
  def init(opts) do
    {:ok,
     %{
       repo: Keyword.fetch!(opts, :repo),
       dynamic_repo: Keyword.get(opts, :dynamic_repo),
       chunk_size: Keyword.fetch!(opts, :chunk_size),
       source: Keyword.fetch!(opts, :source),
       buffers: [],
       count: 0
     }}
  end

  @impl true
  def handle_cast({:insert, entries}, state) do
    entries = List.wrap(entries)

    state =
      Exograph.Hex.StageTimings.measure(InsertBuffer.metric(state.source, :service), fn ->
        count = state.count + length(entries)
        state = %{state | buffers: [entries | state.buffers], count: count}
        if count >= state.chunk_size, do: flush_source(state), else: state
      end)

    {:noreply, state}
  end

  @impl true
  def handle_call(:flush, _from, state) do
    {:reply, :ok, flush_source(state)}
  end

  @impl true
  def terminate(_reason, state) do
    flush_source(state)
    :ok
  end

  defp flush_source(state) do
    entries =
      state.buffers
      |> Enum.reverse()
      |> Enum.flat_map(& &1)

    if entries != [] do
      flush_entries(state, entries)
    end

    %{state | buffers: [], count: 0}
  end

  defp flush_entries(state, entries) do
    InsertBuffer.metric(state.source, :flush_rows)
    |> Exograph.Hex.StageTimings.count(length(entries))

    Exograph.Hex.StageTimings.measure(InsertBuffer.metric(state.source, :flush), fn ->
      with_dynamic_repo(state, fn ->
        state.repo.insert_all(state.source, entries,
          insert_method: :append,
          chunk_every: 10_000,
          timeout: :infinity
        )
      end)
    end)
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
