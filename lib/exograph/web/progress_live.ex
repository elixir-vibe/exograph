defmodule Exograph.Web.ProgressLive do
  @moduledoc false

  use Exograph.Web, :live_view

  alias Exograph.Hex.Progress

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Progress.subscribe()
      Process.send_after(self(), :tick, 1000)
    end

    {:ok, assign(socket, progress: Progress.get())}
  end

  @impl true
  def handle_info({:progress, progress}, socket) do
    {:noreply, assign(socket, progress: progress)}
  end

  def handle_info(:tick, socket) do
    Process.send_after(self(), :tick, 1000)
    {:noreply, assign(socket, progress: Progress.get())}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="min-h-screen bg-zinc-950 text-zinc-200">
      <div class="max-w-2xl mx-auto px-4 py-6">
        <div :if={@progress.state == :idle} class="text-zinc-500 text-center py-16 text-sm">
          <p class="text-lg font-bold text-white mb-4">Hex Indexer</p>
          <p>No indexing in progress.</p>
          <p class="mt-1 text-xs">
            <code class="text-zinc-400 bg-zinc-800 px-1 py-0.5 rounded">mix exograph.index.hex --web</code>
          </p>
        </div>

        <div :if={@progress.state != :idle}>
          <%!-- Header --%>
          <div class="flex items-center gap-2 mb-4">
            <span class="text-sm font-bold text-white">Hex Indexer</span>
            <span class={["px-1.5 py-px text-[10px] rounded", status_badge(@progress.state)]}>
              {status_label(@progress.state)}
            </span>
          </div>

          <%!-- Progress bar --%>
          <div class="mb-4">
            <div class="flex items-baseline justify-between text-xs text-zinc-500 mb-1">
              <span class="tabular-nums">
                {@progress.processed} / {@progress.total}
              </span>
              <span class="tabular-nums">{pct(@progress)}%</span>
            </div>
            <div class="h-1.5 bg-zinc-800 rounded-full overflow-hidden">
              <div
                class={[
                  "h-full rounded-full transition-all duration-500",
                  if(@progress.state == :done, do: "bg-green-500", else: "bg-blue-500")
                ]}
                style={"width: #{pct(@progress)}%"}
              >
              </div>
            </div>
            <div class="flex justify-between text-[11px] text-zinc-600 mt-1 tabular-nums">
              <span>{rate(@progress)} pkg/s</span>
              <span :if={@progress.state == :running}>ETA {eta(@progress)}</span>
              <span :if={@progress.state == :done}>{elapsed(@progress)}</span>
            </div>
          </div>

          <%!-- Stats row --%>
          <div class="flex gap-2 mb-4">
            <div class="flex-1 bg-zinc-900 rounded border border-zinc-800 px-3 py-1.5">
              <span class="text-sm font-bold text-green-400 tabular-nums">{@progress.ok}</span>
              <span class="text-[11px] text-zinc-600 ml-1">indexed</span>
            </div>
            <div class="flex-1 bg-zinc-900 rounded border border-zinc-800 px-3 py-1.5">
              <span class="text-sm font-bold text-zinc-500 tabular-nums">{@progress.skipped}</span>
              <span class="text-[11px] text-zinc-600 ml-1">skipped</span>
            </div>
            <div class="flex-1 bg-zinc-900 rounded border border-zinc-800 px-3 py-1.5">
              <span class="text-sm font-bold text-red-400 tabular-nums">{@progress.errors}</span>
              <span class="text-[11px] text-zinc-600 ml-1">failed</span>
            </div>
          </div>

          <div :if={map_size(@progress.broadway) > 0} class="rounded border border-zinc-800 overflow-hidden mb-4">
            <div class="px-3 py-1.5 text-[11px] text-zinc-500 bg-zinc-900 border-b border-zinc-800">
              Broadway
            </div>
            <div class="grid grid-cols-2 gap-px bg-zinc-800 text-[11px]">
              <div class="bg-zinc-950 px-3 py-2">
                <div class="text-zinc-600">processor</div>
                <div class="text-zinc-300 tabular-nums">{stage_messages(@progress, :processor)} msgs</div>
              </div>
              <div class="bg-zinc-950 px-3 py-2">
                <div class="text-zinc-600">shard batches</div>
                <div class="text-zinc-300 tabular-nums">{stage_batches(@progress, :batcher)}</div>
              </div>
            </div>
            <div :if={stage_metrics(@progress, :batcher) != []} class="divide-y divide-zinc-800/70">
              <div :for={{key, metric} <- stage_metrics(@progress, :batcher)} class="flex items-center justify-between px-3 py-1 text-[11px]">
                <span class="text-zinc-500">shard {key}</span>
                <span class="text-zinc-300 tabular-nums">
                  {metric.messages} msgs · {metric.batches} batches · last {metric.last_batch}
                </span>
              </div>
            </div>
          </div>

          <%!-- Current package --%>
          <div
            :if={@progress.current && @progress.state == :running}
            class="flex items-center gap-2 text-xs text-zinc-500 mb-3"
          >
            <div class="w-3 h-3 border-[1.5px] border-blue-400 border-t-transparent rounded-full animate-spin shrink-0">
            </div>
            <span class="font-mono text-zinc-400">
              {@progress.current.name}<span class="text-zinc-600">@{@progress.current.version}</span>
            </span>
          </div>

          <%!-- Recent activity --%>
          <div class="rounded border border-zinc-800 overflow-hidden">
            <div class="px-3 py-1.5 text-[11px] text-zinc-500 bg-zinc-900 border-b border-zinc-800">
              Recent
            </div>
            <div class="max-h-[60vh] overflow-y-auto scrollbar-thin scrollbar-thumb-zinc-700 scrollbar-track-transparent">
              <div
                :for={item <- @progress.recent}
                class="flex items-center justify-between px-3 py-1 border-b border-zinc-800/30 last:border-0"
              >
                <div class="flex items-center gap-2 min-w-0">
                  <span class={["w-1.5 h-1.5 rounded-full shrink-0", dot_color(item.status)]}></span>
                  <span class="font-mono text-[11px] text-zinc-400 truncate">
                    {item.name}<span class="text-zinc-600">@{item.version}</span>
                  </span>
                </div>
                <span class={["text-[11px] shrink-0 ml-3", status_color(item.status)]} title={item.reason}>
                  {status_text(item.status)}
                </span>
              </div>
              <div :if={@progress.recent == []} class="px-3 py-6 text-center text-zinc-600 text-xs">
                Waiting…
              </div>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp stage_metrics(%{broadway: broadway}, stage) do
    broadway
    |> Map.get(stage, %{})
    |> Enum.sort_by(fn {key, _metric} -> key end)
  end

  defp stage_messages(progress, stage) do
    progress
    |> stage_metrics(stage)
    |> Enum.sum_by(fn {_key, metric} -> metric.messages end)
  end

  defp stage_batches(progress, stage) do
    progress
    |> stage_metrics(stage)
    |> Enum.sum_by(fn {_key, metric} -> metric.batches end)
  end

  defp pct(%{total: 0}), do: 0
  defp pct(%{processed: p, total: t}), do: Float.round(p / t * 100, 1)

  defp rate(%{processed: 0}), do: "—"

  defp rate(%{processed: p, started_at: started}) do
    elapsed_s = (System.monotonic_time(:millisecond) - started) / 1000
    if elapsed_s > 0, do: Float.round(p / elapsed_s, 1), else: "—"
  end

  defp eta(%{processed: p, total: t, started_at: started}) when p > 0 do
    elapsed_s = (System.monotonic_time(:millisecond) - started) / 1000
    rate = p / max(elapsed_s, 0.1)
    format_duration((t - p) / rate)
  end

  defp eta(_), do: "—"

  defp elapsed(%{started_at: s, finished_at: f}) when is_integer(s) and is_integer(f) do
    format_duration((f - s) / 1000)
  end

  defp elapsed(_), do: "—"

  defp format_duration(seconds), do: Exograph.Duration.format(seconds)

  defp status_badge(:running), do: "bg-blue-500/15 text-blue-400"
  defp status_badge(:done), do: "bg-green-500/15 text-green-400"

  defp status_label(:running), do: "Running"
  defp status_label(:done), do: "Complete"

  defp dot_color(:ok), do: "bg-green-400"
  defp dot_color(:skipped), do: "bg-zinc-600"
  defp dot_color({:error, _}), do: "bg-red-400"

  defp status_color(:ok), do: "text-green-500/70"
  defp status_color(:skipped), do: "text-zinc-600"
  defp status_color({:error, _}), do: "text-red-400"

  defp status_text(:ok), do: "indexed"
  defp status_text(:skipped), do: "skipped"

  defp status_text({:error, reason}) do
    msg = inspect(reason, limit: 40)
    if String.length(msg) > 50, do: String.slice(msg, 0, 47) <> "…", else: "failed: #{msg}"
  end
end
