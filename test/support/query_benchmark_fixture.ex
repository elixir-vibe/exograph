defmodule Exograph.QueryBenchmarkFixture do
  @moduledoc false

  import Ecto.Query

  alias Exograph.DuckDBSupport
  alias Exograph.Storage.{FragmentRecord, Schema}

  def build_index! do
    DuckDBSupport.start_managed_repo!()
    prefix = "query_benchmark_#{System.unique_integer([:positive])}"

    {:ok, index} =
      Exograph.index_sources(
        sources(),
        DuckDBSupport.opts(prefix, extractors: [:ex_ast], min_mass: 1)
      )

    seed_call_edge!(index)
    index
  end

  defp seed_call_edge!(index) do
    fragments_source = Schema.fragments_source(index.inverted.prefix)

    fragment =
      index.inverted.repo.one!(
        from(fragment in {fragments_source, FragmentRecord},
          where: fragment.module == "Benchmark.Fixture1" and fragment.name == "run"
        )
      )

    graph_nodes_source = Schema.graph_nodes_source(index.inverted.prefix)
    now = DateTime.utc_now()

    index.inverted.repo.insert_all(graph_nodes_source, [
      %{
        file_id: fragment.file_id,
        fragment_id: fragment.id,
        engine: "benchmark",
        external_id: "benchmark-run",
        kind: :function,
        module: "Benchmark.Fixture1",
        name: "run",
        arity: 1,
        qualified_name: "Benchmark.Fixture1.run/1",
        line: fragment.line,
        column: 1,
        metadata: %{},
        inserted_at: now,
        updated_at: now
      },
      %{
        file_id: nil,
        fragment_id: nil,
        engine: "benchmark",
        external_id: "benchmark-helper",
        kind: :external_function,
        module: "Benchmark.Fixture1",
        name: "helper",
        arity: 1,
        qualified_name: "Benchmark.Fixture1.helper/1",
        line: fragment.line,
        column: 1,
        metadata: %{},
        inserted_at: now,
        updated_at: now
      }
    ])

    nodes =
      index.inverted.repo.all(
        from(node in graph_nodes_source,
          where: node.external_id in ["benchmark-run", "benchmark-helper"]
        )
      )
      |> Map.new(&{&1.external_id, &1})

    call_edges_source = Schema.call_edges_source(index.inverted.prefix)

    index.inverted.repo.insert_all(call_edges_source, [
      %{
        file_id: fragment.file_id,
        caller_node_id: nodes["benchmark-run"].id,
        callee_node_id: nodes["benchmark-helper"].id,
        call_site_fragment_id: fragment.id,
        caller_qualified_name: "Benchmark.Fixture1.run/1",
        callee_qualified_name: "Benchmark.Fixture1.helper/1",
        line: fragment.line,
        column: 1,
        metadata: %{},
        inserted_at: now,
        updated_at: now
      }
    ])
  end

  def sources do
    Enum.map(1..24, fn number ->
      name = "Fixture#{number}"

      {"lib/benchmark/#{Macro.underscore(name)}.ex",
       """
       defmodule Benchmark.#{name} do
         # benchmark marker #{number}
         def run(value) do
           helper(value)
           Enum.map([value], & &1)
         end

         def helper(value), do: value
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
