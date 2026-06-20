defmodule Exograph.Web.QueryExecutor do
  @moduledoc false

  alias Exograph.Web.SafeEval

  @default_limit 100

  def default_limit, do: @default_limit

  def execute(index, query_string, opts \\ []) do
    mode = Keyword.get(opts, :mode, "structural")
    limit = Keyword.get(opts, :limit, @default_limit)
    skip = Keyword.get(opts, :skip, 0)
    query_opts = Keyword.merge(Keyword.drop(opts, [:mode]), limit: limit, skip: skip)

    {elapsed_us, result} =
      :timer.tc(fn ->
        case mode do
          "text" ->
            {:ok, results} = Exograph.search_text(index, query_string, query_opts)
            {:ok, results, limit, nil}

          _ ->
            case SafeEval.eval(query_string) do
              {:ok, parsed} -> run_parsed(index, parsed, query_opts)
              {:error, _} = error -> error
            end
        end
      end)

    case result do
      {:ok, results, effective_limit, total} ->
        {:ok, results, Float.round(elapsed_us / 1000, 1), effective_limit, total}

      {:error, error} ->
        {:error, error}
    end
  end

  defp run_parsed(index, %Exograph.DSL.Query{} = query, opts) do
    default_limit = Keyword.fetch!(opts, :limit)
    effective_limit = query.limit || default_limit
    total = query.limit
    query_opts = Keyword.put(opts, :limit, effective_limit)

    case Exograph.all(index, query, query_opts) do
      {:ok, results} -> {:ok, results, effective_limit, total}
      error -> error
    end
  end

  defp run_parsed(index, pattern, opts) when is_binary(pattern) do
    limit = Keyword.fetch!(opts, :limit)

    case Exograph.search(index, pattern, opts) do
      {:ok, results} -> {:ok, results, limit, nil}
      error -> error
    end
  end
end
