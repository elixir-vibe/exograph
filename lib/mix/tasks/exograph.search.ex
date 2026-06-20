defmodule Mix.Tasks.Exograph.Search do
  use Mix.Task

  @shortdoc "Searches an Elixir codebase with Exograph"

  @moduledoc """
  Searches Elixir source files with Exograph's DuckDB/QuackDB storage.

      mix exograph.search 'Repo.get!(_, _)' --migrate
      mix exograph.search 'def _ do ... end' lib --contains 'Repo.transaction(_)'
      mix exograph.search 'def _ do ... end' lib --contains 'Repo.transaction(_)' --not-contains 'IO.inspect(_)'
      mix exograph.search '/users/:id' lib --text
      mix exograph.search 'Repo\\.get!\\(' lib --regex

  ## Options

    * `--repo` - Ecto repo module for a QuackDB-backed DuckDB repo
    * `--prefix` - Exograph table prefix (default: `exograph`)
    * `--migrate` - create/upgrade DuckDB tables and text indexes
    * `--no-bm25` - skip BM25/full-text index creation during migration/finalization
    * `--quackdb-uri` - QuackDB URI when `--repo` is omitted
    * `--quackdb-token` - QuackDB token
    * `--duckdb-database` - managed DuckDB database path when `--quackdb-uri` is omitted
    * `--duckdb-threads` - DuckDB execution threads for indexing/query setup
    * `--min-mass` - minimum AST fragment mass (default: `8`)
    * `--limit` - maximum results (default: `20`)
    * `--contains` - require descendant pattern, can be repeated
    * `--not-contains` - reject descendant pattern, can be repeated; verifier-only
    * `--no-verify` - skip final ExAST verification
    * `--json` - print JSON results
    * `--text` - literal source text search instead of AST query
    * `--regex` - regex source text search instead of AST query
  """

  @impl true
  def run(args) do
    Mix.Task.run("app.start")

    {opts, positional, invalid} =
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
          limit: :integer,
          contains: :keep,
          not_contains: :keep,
          no_verify: :boolean,
          json: :boolean,
          text: :boolean,
          regex: :boolean
        ],
        aliases: [n: :limit]
      )

    if invalid != [] do
      Mix.raise("Invalid options: #{inspect(invalid)}")
    end

    case positional do
      [] ->
        Mix.raise("Expected a query pattern or text. See `mix help exograph.search`.")

      [query | paths] ->
        run_search(query, if(paths == [], do: ["lib"], else: paths), opts)
    end
  end

  defp run_search(query_text, paths, opts) do
    min_mass = Keyword.get(opts, :min_mass, 8)
    limit = Keyword.get(opts, :limit, 20)
    index_opts = Mix.Exograph.DuckDBOptions.opts(opts)

    {:ok, index} = Exograph.index(paths, Keyword.merge([min_mass: min_mass], index_opts))

    cond do
      Keyword.get(opts, :text, false) ->
        {:ok, results} = Exograph.search_text(index, query_text, limit: limit)
        print_results(results, opts)

      Keyword.get(opts, :regex, false) ->
        {:ok, regex} = Regex.compile(query_text)
        {:ok, results} = Exograph.search_text(index, regex, limit: limit)
        print_results(results, opts)

      true ->
        query = ast_query(query_text, opts)

        {:ok, results} =
          Exograph.search(index, query,
            limit: limit,
            verify: !Keyword.get(opts, :no_verify, false)
          )

        print_results(results, opts)
    end
  end

  defp ast_query(pattern, opts) do
    contains = Keyword.get_values(opts, :contains)
    not_contains = Keyword.get_values(opts, :not_contains)

    if contains == [] and not_contains == [] do
      pattern
    else
      selector = ExAST.Selector.from(pattern)

      selector =
        Enum.reduce(contains, selector, fn pattern, selector ->
          ExAST.Selector.where_predicate(selector, ExAST.Selector.contains(pattern))
        end)

      Enum.reduce(not_contains, selector, fn pattern, selector ->
        ExAST.Selector.where_predicate(
          selector,
          ExAST.Selector.contains(pattern) |> ExAST.Selector.not()
        )
      end)
    end
  end

  defp print_results(results, opts) do
    if Keyword.get(opts, :json, false) do
      Mix.shell().info(json(%{results: Enum.map(results, &result_json/1)}))
    else
      Mix.shell().info("#{length(results)} result(s)")
      Enum.each(results, &print_result/1)
    end
  end

  defp print_result(%{fragment: fragment} = result) do
    {line, label} = result_label(result)
    score = Map.get(result, :score, 0.0)

    Mix.shell().info("#{fragment.file}:#{line} #{label} score=#{Float.round(score * 1.0, 3)}")
  end

  defp result_label(%{match: %{node: node}}), do: node_label(node)

  defp result_label(%{fragment: fragment}) do
    label = [fragment.kind, fragment.name || ""] |> Enum.join(" ") |> String.trim()
    {fragment.line, label}
  end

  defp node_label({form, meta, [head | _]}) when form in [:def, :defp, :defmacro, :defmacrop] do
    case unwrap_head(head) do
      {name, _, args} when is_atom(name) and is_list(args) ->
        {Keyword.get(meta, :line, 0), "#{form} #{name}/#{length(args)}"}

      {name, _, nil} when is_atom(name) ->
        {Keyword.get(meta, :line, 0), "#{form} #{name}/0"}

      _ ->
        {Keyword.get(meta, :line, 0), Atom.to_string(form)}
    end
  end

  defp node_label({form, meta, _args}) when is_atom(form),
    do: {Keyword.get(meta, :line, 0), Atom.to_string(form)}

  defp node_label(_node), do: {0, "match"}

  defp unwrap_head({:when, _, [head | _]}), do: unwrap_head(head)
  defp unwrap_head(head), do: head

  defp result_json(%{fragment: fragment} = result) do
    %{
      file: fragment.file,
      line: fragment.line,
      kind: fragment.kind,
      name: fragment.name,
      score: Map.get(result, :score, 0.0)
    }
  end

  defp json(value), do: JSON.encode!(value)
end
