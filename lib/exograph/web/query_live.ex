defmodule Exograph.Web.QueryLive do
  @moduledoc false

  use Exograph.Web, :live_view

  import Exograph.Web.ResultFormatter, only: [display_name: 1, badge_class: 1]

  alias Exograph.Storage.Schema
  alias Exograph.Web.IndexStats
  alias Exograph.Web.QueryExecutor
  alias Exograph.Web.ResultFormatter

  @default_query """
  from(f in Fragment,
    where: matches(f, "def handle_event(_, _, _) do ... end"),
    limit: 20
  )\
  """

  @examples [
    {"LiveView handle_event callbacks",
     "Find LiveView-style handle_event/3 callbacks in Hex packages",
     ~S"""
     from(f in Fragment,
       where: matches(f, "def handle_event(_, _, _) do ... end"),
       limit: 20)
     """},
    {"LiveView render functions",
     "Find render/1 callbacks in modules that mention Phoenix.LiveView",
     ~S"""
     from(f in Fragment,
       where: matches(f, "def render(_) do ... end"),
       where: contains(f, "Phoenix.LiveView"),
       limit: 20)
     """},
    {"Parser atom audit", "Join references and source text to inspect String.to_atom/1 usage",
     ~S"""
     from(f in Fragment,
       join: r in assoc(f, :references),
       where: r.qualified_name == "String.to_atom/1",
       where: f.kind in [:def, :defp],
       where: contains(f, "parse"),
       where: matches(f, "def _ do ... end"),
       select: {f, r},
       limit: 20)
     """},
    {"Safe binary_to_term contrast",
     "Find [:safe] counterexamples for unsafe deserialization rules",
     ~S'from(f in Fragment, where: contains(f, ":erlang.binary_to_term(_, [:safe])"), limit: 20)'},
    {"Raw HTML audit", "Join Phoenix.HTML.raw/1 references with surrounding function source",
     ~S"""
     from(f in Fragment,
       join: r in assoc(f, :references),
       where: r.qualified_name == "Phoenix.HTML.raw/1",
       where: f.kind in [:def, :defp],
       where: contains(f, "safe"),
       select: {f, r},
       limit: 20)
     """},
    {"Repo call inside Enum.map", "Search for N+1-style Repo work inside enumerable callbacks",
     ~S"""
     from(f in Fragment,
       where: matches(f, "def _ do Enum.map(_, fn _ -> ... end) end"),
       where: contains(f, "Repo."),
       limit: 20)
     """}
  ]

  @impl true
  def mount(_params, _session, socket) do
    index = Application.get_env(:exograph, :web_index)
    prefix = Application.get_env(:exograph, :web_prefix)
    package_count = IndexStats.package_count(index)

    {:ok,
     assign(socket,
       index: index,
       prefix: prefix,
       package_count: package_count,
       query: @default_query,
       initial_query: @default_query,
       examples: @examples,
       results: nil,
       error: nil,
       elapsed_ms: nil,
       result_count: nil,
       loading: false,
       collapsed_packages: MapSet.new(),
       all_results: [],
       has_more: false,
       current_page: 1,
       page_size: 20,
       total_pages: 1,
       total_results: nil,
       query_meta: nil,
       viewing_source: nil
     )}
  end

  @impl true
  def handle_params(%{"q" => q} = params, _uri, socket) when q != "" do
    page = parse_page(params["page"])

    socket =
      socket
      |> push_event("set_editor_value", %{value: q})
      |> start_query(q, page)

    {:noreply, socket}
  end

  def handle_params(_params, _uri, socket), do: {:noreply, socket}

  @impl true
  def handle_event("set_query", %{"query" => query}, socket) do
    {:noreply, push_event(socket, "set_editor_value", %{value: String.trim(query)})}
  end

  @impl true
  def handle_event("format", %{"query" => query}, socket) do
    formatted = Code.format_string!(query, line_length: 80) |> IO.iodata_to_binary()
    {:noreply, push_event(socket, "set_editor_value", %{value: formatted})}
  rescue
    _ -> {:noreply, socket}
  end

  @impl true
  def handle_event("toggle_package", %{"package" => name}, socket) do
    collapsed =
      if MapSet.member?(socket.assigns.collapsed_packages, name) do
        MapSet.delete(socket.assigns.collapsed_packages, name)
      else
        MapSet.put(socket.assigns.collapsed_packages, name)
      end

    {:noreply, assign(socket, collapsed_packages: collapsed)}
  end

  @impl true
  def handle_event("run", %{"query" => query}, socket) do
    {:noreply, start_query(socket, query, 1)}
  end

  @impl true
  def handle_event("next_page", _params, socket) do
    page = socket.assigns.current_page + 1
    go_to_page(socket, page)
  end

  def handle_event("prev_page", _params, socket) do
    page = max(socket.assigns.current_page - 1, 1)
    go_to_page(socket, page)
  end

  def handle_event("go_to_page", %{"page" => page}, socket) do
    go_to_page(socket, String.to_integer(page))
  end

  def handle_event(
        "view_source",
        %{"file" => file, "line" => line, "package" => package} = params,
        socket
      ) do
    line = String.to_integer(line)
    package_version = blank_to_nil(params["package-version"] || params["package_version"])
    source = fetch_file_source(socket.assigns, file)

    socket =
      socket
      |> assign(
        viewing_source: %{
          file: file,
          source: source,
          line: line,
          package: package,
          package_version: package_version
        }
      )
      |> push_event("scroll_to_line", %{line: line})

    {:noreply, socket}
  end

  def handle_event("close_source", _params, socket) do
    {:noreply, assign(socket, viewing_source: nil)}
  end

  def handle_event("completion", %{"hint" => hint}, socket) do
    items = Exograph.Web.Completion.complete(hint, socket.assigns.index)
    {:reply, %{items: items}, socket}
  end

  defp go_to_page(socket, page) do
    {:noreply, start_query(socket, socket.assigns.query, page)}
  end

  defp start_query(socket, query, page) do
    index = socket.assigns.index
    page_size = socket.assigns.page_size
    page = max(page, 1)
    skip = (page - 1) * page_size
    pid = self()

    socket =
      assign(socket,
        query: query,
        error: nil,
        results: nil,
        elapsed_ms: nil,
        result_count: nil,
        loading: true,
        all_results: [],
        current_page: page,
        total_pages: page,
        total_results: nil,
        query_meta: nil,
        has_more: false
      )

    Task.start(fn ->
      result =
        QueryExecutor.execute(index, query, skip: skip, limit: page_size, mode: "structural")

      send(pid, {:query_result, query, result, :replace})
    end)

    socket
  end

  @impl true
  def handle_info({:query_result, query, result, _mode}, socket) do
    socket =
      case result do
        {:ok, new_results, elapsed_ms, effective_limit, total, meta} ->
          page_size = socket.assigns.page_size

          total_pages =
            cond do
              is_integer(total) and total > 0 ->
                ceil(total / page_size)

              is_integer(total) ->
                1

              length(new_results) >= min(effective_limit, page_size) ->
                socket.assigns.current_page + 1

              true ->
                socket.assigns.current_page
            end

          has_more =
            if is_integer(total) do
              socket.assigns.current_page < total_pages
            else
              length(new_results) >= min(effective_limit, page_size)
            end

          socket
          |> assign(
            all_results: new_results,
            results: ResultFormatter.format(new_results),
            result_count: length(new_results),
            elapsed_ms: elapsed_ms,
            has_more: has_more,
            total_pages: total_pages,
            total_results: total,
            query_meta: meta,
            loading: false
          )
          |> push_event("set_diagnostics", %{markers: []})
          |> push_event("update_url", %{q: query, page: socket.assigns.current_page})

        {:error, %{message: message, markers: markers}} ->
          socket
          |> assign(error: message, loading: false, has_more: false)
          |> push_event("set_diagnostics", %{markers: markers})

        {:error, message} when is_binary(message) ->
          assign(socket, error: message, loading: false, has_more: false)
      end

    {:noreply, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex flex-col h-full">
      <header class="flex flex-col gap-3 px-4 py-3 border-b border-zinc-800 sm:flex-row sm:items-center sm:justify-between sm:px-6">
        <div class="flex min-w-0 flex-wrap items-baseline gap-x-3 gap-y-1">
          <h1 class="text-lg font-semibold tracking-tight">
            <.link navigate={@prefix || "/"} class="hover:text-blue-400 transition-colors">Exograph</.link>
          </h1>
          <span class="text-xs text-zinc-500">{@package_count} packages indexed</span>
        </div>
        <div class="flex w-full flex-wrap items-center gap-2 text-sm text-zinc-400 sm:w-auto sm:justify-end sm:gap-4">
          <span :if={@result_count} class="min-w-0 flex-1 tabular-nums sm:flex-none">
            <span :if={@total_results}>Showing {@result_count} of {@total_results} results</span>
            <span :if={!@total_results}>Showing {@result_count} results</span>
            <span class="text-zinc-600">·</span>
            <span>{@elapsed_ms}ms</span>
          </span>
          <button
            id="fmt-btn"
            phx-hook="FormatButton"
            class="px-3 py-1.5 text-sm font-medium text-zinc-400 bg-zinc-800 rounded-md hover:bg-zinc-700 hover:text-zinc-200 cursor-pointer transition-colors"
          >
            Format
          </button>
          <button
            id="run-btn"
            phx-hook="RunButton"
            class={"px-3 py-1.5 text-sm font-medium bg-blue-600 text-white rounded-md hover:bg-blue-500 cursor-pointer transition-colors" <> if(@loading, do: " opacity-75 pointer-events-none", else: "")}
          >
            <span :if={@loading} class="inline-flex items-center gap-2">
              <span class="inline-block w-4 h-4 border-2 border-white/30 border-t-white rounded-full animate-spin">
              </span>
              Running…
            </span>
            <span :if={not @loading}>Run ⌘↵</span>
          </button>
        </div>
      </header>

      <div class="flex flex-col flex-1 min-h-0">
        <div id="editor-wrapper" class="h-[120px] border-b border-zinc-800 sm:h-[160px]" phx-update="ignore">
          <div
            id="editor"
            phx-hook="Editor"
            class="h-full"
            data-query={@initial_query}
          />
        </div>

        <div id="results-wrapper" class="flex-1 overflow-auto scrollbar-thin scrollbar-thumb-zinc-700 scrollbar-track-transparent p-3 space-y-3 sm:p-4">
          <div :if={@error} class="p-4 text-red-400 font-mono text-sm whitespace-pre-wrap">
            {@error}
          </div>

          <div
            :if={@query_meta && @query_meta.notices != []}
            class="rounded-lg border border-amber-900/60 bg-amber-950/30 p-4 text-sm text-amber-100 space-y-2"
          >
            <div class="font-medium">Search notice</div>
            <div :for={notice <- @query_meta.notices} class="text-amber-200/90">
              {notice.message}
            </div>
            <div
              :if={@query_meta.partial || @query_meta.shards.failed > 0}
              class="text-xs text-amber-300/70"
            >
              Searched {@query_meta.shards.successful}/{@query_meta.shards.total} shards.
            </div>
          </div>

          <div :for={group <- (@results || [])} class="rounded-lg border border-zinc-800 overflow-hidden">
            <div
              class="flex w-full cursor-pointer flex-wrap items-center gap-2 px-3 py-2.5 bg-zinc-900 border-b border-zinc-800 hover:bg-zinc-800/50 transition-colors sm:gap-3 sm:px-4"
              phx-click="toggle_package"
              phx-value-package={group.key}
            >
              <.icon
                name="heroicons:chevron-right"
                class={"w-4 h-4 text-zinc-500 transition-transform" <> if(MapSet.member?(@collapsed_packages, group.key), do: "", else: " rotate-90")}
              />
              <a
                href={group.package_url}
                target="_blank"
                class="min-w-0 max-w-full truncate text-sm font-semibold text-zinc-200 hover:text-blue-400"
                onclick="event.stopPropagation()"
              >
                {group.package}
              </a>
              <span
                :if={group.package_version}
                class="text-xs text-emerald-300/90 bg-emerald-950/50 border border-emerald-900/60 rounded-full px-2 py-0.5 font-mono"
              >
                v{group.package_version}
              </span>
              <span class="text-xs text-zinc-500 bg-zinc-800 rounded-full px-2 py-0.5 tabular-nums">
                {group.count} results
              </span>
            </div>

            <div :if={not MapSet.member?(@collapsed_packages, group.key)} class="divide-y divide-zinc-800">
              <div :for={file_group <- group.files}>
                <div class="flex min-w-0 items-center gap-2 px-3 py-2 bg-zinc-900/40 border-b border-zinc-800/50 sm:px-4">
                  <.icon name="heroicons:document-text" class="w-3.5 h-3.5 text-zinc-500 shrink-0" />
                  <a
                    :if={file_group.source_url}
                    href={file_group.source_url}
                    target="_blank"
                    class="min-w-0 truncate text-blue-400 font-mono text-xs hover:text-blue-300"
                  >
                    {file_group.file}
                  </a>
                  <span :if={!file_group.source_url} class="min-w-0 truncate text-blue-400 font-mono text-xs">
                    {file_group.file}
                  </span>
                </div>

                <div class="divide-y divide-zinc-800/40">
                  <div :for={result <- file_group.results} class="px-3 py-3 sm:px-4">
                    <div class="flex items-center gap-2 mb-2 flex-wrap">
                      <span class={"inline-flex items-center px-1.5 py-0.5 text-xs rounded font-medium " <> badge_class(result.kind)}>
                        {to_string(result.kind)}
                      </span>
                      <span class="min-w-0 break-all text-zinc-200 font-mono text-sm sm:break-normal">{display_name(result)}</span>
                      <span :if={result.module} class="text-zinc-500 text-xs font-mono">
                        {result.module}
                      </span>
                      <span class="ml-0 text-zinc-600 text-xs tabular-nums sm:ml-auto">
                        line {result.line}
                      </span>
                      <button
                        phx-click="view_source"
                        phx-value-file={result.file}
                        phx-value-line={to_string(result.line)}
                        phx-value-package={result.package}
                        phx-value-package-version={result.package_version || ""}
                        class="text-zinc-600 hover:text-zinc-400 cursor-pointer ml-1"
                        title="View full source"
                      >
                        <.icon name="heroicons:code-bracket" class="w-3.5 h-3.5" />
                      </button>
                      <span
                        :if={result.joined_label}
                        class="basis-full text-zinc-500 text-xs font-mono sm:basis-auto sm:ml-2"
                      >
                        {result.joined_label}
                      </span>
                    </div>

                    <div :if={result.preview} class="code-preview rounded border border-zinc-800 overflow-x-auto py-1">
                      <div
                        :for={{line_num, html, is_matched} <- result.preview}
                        class={"flex font-mono" <> if(is_matched, do: " bg-blue-900/20 border-l-2 border-l-blue-500", else: "")}
                      >
                        <span class="w-10 text-right pr-3 text-zinc-600 select-none shrink-0 bg-zinc-900/50 border-r border-zinc-800/50 tabular-nums">{line_num}</span><code class="px-3 min-w-max flex-1 text-zinc-300 whitespace-pre">{raw(html)}</code>
                      </div>
                    </div>
                  </div>
                </div>
              </div>
            </div>
          </div>

          <nav
            :if={@has_more || @current_page > 1}
            class="flex items-center justify-center gap-0.5 py-3"
          >
            <button
              phx-click="prev_page"
              disabled={@current_page == 1}
              class={[
                "px-2 py-1 text-xs rounded transition-colors",
                if(@current_page == 1,
                  do: "text-zinc-700 cursor-default",
                  else: "text-zinc-400 hover:bg-zinc-800 hover:text-zinc-200 cursor-pointer"
                )
              ]}
            >
              Previous
            </button>
            <.page_btn
              :for={page <- page_window(@current_page, @total_pages)}
              page={page}
              current={@current_page}
            />
            <button
              phx-click="next_page"
              disabled={!@has_more}
              class={[
                "px-2 py-1 text-xs rounded transition-colors",
                if(@has_more,
                  do: "text-zinc-400 hover:bg-zinc-800 hover:text-zinc-200 cursor-pointer",
                  else: "text-zinc-700 cursor-default"
                )
              ]}
            >
              Next
            </button>
          </nav>

          <div :if={@results == []} class="p-8 text-center text-zinc-500">No results</div>
          <div :if={is_nil(@results) && is_nil(@error)} class="px-6 py-8">
            <p class="text-sm text-zinc-500 mb-4">Try an example:</p>
            <div class="grid grid-cols-1 gap-3 max-w-2xl sm:grid-cols-2">
              <button
                :for={{label, desc, query} <- @examples}
                phx-click="set_query"
                phx-value-query={query}
                class="text-left p-4 rounded-lg border border-zinc-800 bg-zinc-900/50 hover:bg-zinc-800/50 hover:border-zinc-700 cursor-pointer transition-colors"
              >
                <div class="text-sm font-medium text-zinc-200">{label}</div>
                <div class="text-xs text-zinc-500 mt-1">{desc}</div>
              </button>
            </div>
          </div>
        </div>
      </div>

      <div
        :if={@viewing_source}
        class="fixed inset-0 z-50 flex items-center justify-center bg-black/70"
      >
        <div
          class="bg-zinc-900 rounded-lg border border-zinc-700 w-[96vw] h-[86dvh] flex flex-col sm:w-[90vw] sm:h-[80vh]"
          phx-click-away="close_source"
        >
          <div class="flex items-start justify-between gap-3 px-3 py-3 border-b border-zinc-800 sm:px-4">
            <div class="flex min-w-0 flex-wrap items-center gap-2">
              <.icon name="heroicons:document-text" class="w-4 h-4 text-zinc-500" />
              <span class="min-w-0 break-all text-sm font-mono text-blue-400">{@viewing_source.file}</span>
              <span class="text-xs text-zinc-500">{@viewing_source.package}</span>
              <span
                :if={@viewing_source.package_version}
                class="text-xs text-emerald-300/90 font-mono"
              >
                v{@viewing_source.package_version}
              </span>
            </div>
            <button
              phx-click="close_source"
              class="text-zinc-500 hover:text-zinc-300 cursor-pointer"
            >
              <.icon name="heroicons:x-mark" class="w-5 h-5" />
            </button>
          </div>
          <div class="flex-1 overflow-auto scrollbar-thin scrollbar-thumb-zinc-700 scrollbar-track-transparent">
            <div class="code-preview py-2">
              <div
                :for={
                  {line_num, html, is_highlighted} <-
                    highlight_full_source(@viewing_source.source, @viewing_source.line)
                }
                id={"source-line-#{line_num}"}
                class={"flex font-mono" <> if(is_highlighted, do: " bg-blue-900/30 border-l-2 border-l-blue-500", else: "")}
              >
                <span class="w-12 text-right pr-3 text-zinc-600 select-none shrink-0 bg-zinc-900/50 border-r border-zinc-800/50 tabular-nums">{line_num}</span><code class="px-3 min-w-max flex-1 text-zinc-300 whitespace-pre">{raw(html)}</code>
              </div>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  attr(:page, :any, required: true)
  attr(:current, :integer, required: true)

  defp page_btn(%{page: :ellipsis} = assigns) do
    ~H"""
    <span class="px-1 py-1 text-xs text-zinc-600">…</span>
    """
  end

  defp page_btn(assigns) do
    ~H"""
    <button
      phx-click="go_to_page"
      phx-value-page={@page}
      class={[
        "min-w-[28px] px-1.5 py-1 text-xs rounded tabular-nums transition-colors",
        if(@page == @current,
          do: "bg-blue-600 text-white",
          else: "text-zinc-400 hover:bg-zinc-800 hover:text-zinc-200 cursor-pointer"
        )
      ]}
    >
      {@page}
    </button>
    """
  end

  defp page_window(_current, total) when total <= 7, do: Enum.to_list(1..total)

  defp page_window(current, total) when current <= 3 do
    Enum.to_list(1..min(5, total)) ++ [:ellipsis, total]
  end

  defp page_window(current, total) when current >= total - 2 do
    [1, :ellipsis] ++ Enum.to_list(max(total - 4, 1)..total)
  end

  defp page_window(current, total) do
    [1, :ellipsis, current - 1, current, current + 1, :ellipsis, total]
  end

  defp parse_page(nil), do: 1
  defp parse_page(""), do: 1

  defp parse_page(page) when is_binary(page) do
    case Integer.parse(page) do
      {value, ""} when value > 0 -> value
      _ -> 1
    end
  end

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  defp fetch_file_source(assigns, relative_path) do
    import Ecto.Query
    prefix = assigns.prefix
    repo = assigns.index.inverted.repo
    source = Schema.files_source(prefix)

    from(f in source,
      where: ilike(f.path, ^"%#{relative_path}"),
      limit: 1,
      select: f.source
    )
    |> repo.one()
  end

  defp highlight_full_source(nil, _line), do: []

  defp highlight_full_source(source, highlight_line) do
    source
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.map(fn {text, line_num} ->
      html = Exograph.Web.Highlighter.highlight_line(text)
      {line_num, html, line_num == highlight_line}
    end)
  end
end
