defmodule Exograph.QueryBenchmarkFixture do
  @moduledoc false

  alias Exograph.DuckDBSupport

  def build_index! do
    DuckDBSupport.start_managed_repo!()
    prefix = "query_benchmark_#{System.unique_integer([:positive])}"

    {:ok, index} =
      Exograph.index_sources(
        sources(),
        DuckDBSupport.opts(prefix, extractors: [:ex_ast], min_mass: 1)
      )

    index
  end

  def sources do
    Enum.map(1..24, fn number ->
      name = "Fixture#{number}"

      {"lib/benchmark/#{Macro.underscore(name)}.ex",
       """
       defmodule Benchmark.#{name} do
         # benchmark marker #{number}
         def run(value) do
           Enum.map([value], & &1)
         end

         def other(value), do: String.trim(value)
       end
       """}
    end) ++
      [
        {"lib/benchmark/target.ex",
         """
         defmodule Benchmark.Target do
           # benchmark marker target
           def target(value) do
             Repo.get!(User, value)
           end
         end
         """}
      ]
  end

  def measure(fun) do
    {microseconds, result} = :timer.tc(fun)
    %{elapsed_ms: Float.round(microseconds / 1_000, 3), result: result}
  end
end
