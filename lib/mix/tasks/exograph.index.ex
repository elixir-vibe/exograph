defmodule Mix.Tasks.Exograph.Index do
  use Mix.Task

  @shortdoc "Indexes an Elixir codebase with Exograph"

  @moduledoc """
  Indexes Elixir source files with Exograph's DuckDB/QuackDB storage.

      mix exograph.index --migrate
      mix exograph.index --migrate lib test
      mix exograph.index --min-mass 8 --stats lib

  ## Schema

    * `--repo` - Ecto repo module for a QuackDB-backed DuckDB repo
    * `--prefix` - Exograph table prefix (default: `exograph`)
    * `--migrate` - create/upgrade DuckDB tables and text indexes
    * `--no-bm25` - skip BM25/full-text index creation during migration/finalization
    * `--quackdb-uri` - QuackDB URI when `--repo` is omitted
    * `--quackdb-token` - QuackDB token
    * `--duckdb-database` - managed DuckDB database path when `--quackdb-uri` is omitted
    * `--duckdb-threads` - DuckDB execution threads for indexing/query setup
    * `--min-mass` - minimum AST fragment mass (default: `8`)
    * `--stats` - print indexed fragment statistics
    * `--json` - print summary as JSON
  """

  @impl true
  def run(args) do
    Mix.Task.run("app.start")

    {opts, paths, invalid} =
      OptionParser.parse(args,
        strict: [
          repo: :string,
          prefix: :string,
          migrate: :boolean,
          no_bm25: :boolean,
          quackdb_uri: :string,
          quackdb_token: :string,
          duckdb_database: :string,
          duckdb_threads: :integer,
          min_mass: :integer,
          stats: :boolean,
          json: :boolean
        ]
      )

    if invalid != [] do
      Mix.raise("Invalid options: #{inspect(invalid)}")
    end

    paths = if paths == [], do: ["lib"], else: paths
    min_mass = Keyword.get(opts, :min_mass, 8)
    index_opts = Mix.Exograph.DuckDBOptions.opts(opts)
    started_at = System.monotonic_time()

    case Exograph.index(paths, Keyword.merge([min_mass: min_mass], index_opts)) do
      {:ok, index} ->
        elapsed_ms =
          System.convert_time_unit(System.monotonic_time() - started_at, :native, :millisecond)

        fragments = Exograph.Storage.FragmentStore.all(index.fragment_store)
        summary = summary(paths, fragments, elapsed_ms)

        if Keyword.get(opts, :json, false) do
          Mix.shell().info(json(summary))
        else
          print_summary(summary)
          if Keyword.get(opts, :stats, false), do: print_stats(fragments)
        end

      {:error, reason} ->
        Mix.raise("Failed to index codebase: #{inspect(reason)}")
    end
  end

  defp summary(paths, fragments, elapsed_ms) do
    files = fragments |> Enum.map(& &1.file) |> Enum.uniq()

    %{
      paths: paths,
      files: length(files),
      fragments: length(fragments),
      elapsed_ms: elapsed_ms,
      by_kind: count_by(fragments, & &1.kind)
    }
  end

  defp print_summary(summary) do
    Mix.shell().info(
      "Indexed #{summary.fragments} fragments from #{summary.files} files in #{summary.elapsed_ms}ms"
    )
  end

  defp print_stats(fragments) do
    Mix.shell().info("")
    Mix.shell().info("Fragments by kind:")

    fragments
    |> count_by(& &1.kind)
    |> Enum.sort_by(fn {_kind, count} -> -count end)
    |> Enum.each(fn {kind, count} -> Mix.shell().info("  #{kind}: #{count}") end)
  end

  defp count_by(items, fun) do
    items
    |> Enum.group_by(fun)
    |> Map.new(fn {key, values} -> {key, length(values)} end)
  end

  defp json(summary), do: Jason.encode!(summary, pretty: true)
end
