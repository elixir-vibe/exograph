defmodule Exograph.Integration.AtomSafetyTest do
  use ExUnit.Case, async: false

  alias Exograph.Ident

  @tag :slow
  test "parsing many unique identifiers has bounded atom growth" do
    prefix = "exograph_atom_safety_#{System.unique_integer([:positive])}"
    before_count = :erlang.system_info(:atom_count)

    for index <- 1..10_000 do
      source = """
      defmodule #{Macro.camelize(prefix)}#{index} do
        def #{prefix}_function_#{index}(#{prefix}_arg_#{index}) do
          #{prefix}_local_#{index}(#{prefix}_arg_#{index}, :#{prefix}_literal_#{index})
        end
      end
      """

      assert {:ok, ast} = Exograph.ElixirParser.string_to_quoted(source, line: 1, columns: true)
      assert contains?(ast, Ident.tag("#{prefix}_function_#{index}"))
      assert contains?(ast, Ident.tag("#{prefix}_literal_#{index}"))
    end

    assert :erlang.system_info(:atom_count) - before_count < 100
  end

  @tag :slow
  test "Reach extraction over unique identifiers has bounded atom growth" do
    {:ok, warmup} = Exograph.ElixirParser.string_to_quoted("def warmup(value), do: value")
    assert {:ok, _graph} = Reach.ast_to_graph(warmup, file: "warmup.ex")
    before_count = :erlang.system_info(:atom_count)

    for index <- 1..1_000 do
      source = "def unique_reach_#{index}(argument_#{index}), do: argument_#{index}"
      assert {:ok, ast} = Exograph.ElixirParser.string_to_quoted(source)
      assert {:ok, _graph} = Reach.ast_to_graph(ast, file: "unique_#{index}.ex")
    end

    assert :erlang.system_info(:atom_count) - before_count < 20
  end

  test "compiling unique structural queries has bounded atom growth" do
    _warmup = Exograph.compile("Warmup.Module.call(_)")
    before_count = :erlang.system_info(:atom_count)

    for index <- 1..1_000 do
      query = "UniqueQuery#{index}.call_#{index}(_)"
      compiled = Exograph.compile(query)
      assert "call.remote:UniqueQuery#{index}.call_#{index}/1" in compiled.required_terms
    end

    assert :erlang.system_info(:atom_count) - before_count < 20
  end

  test "lib code does not use unguarded binary_to_term" do
    matches =
      "lib/**/*.ex"
      |> Path.wildcard()
      |> Enum.flat_map(fn path ->
        path
        |> File.read!()
        |> String.split("\n")
        |> Enum.with_index(1)
        |> Enum.filter(fn {line, _line_no} ->
          String.contains?(line, "binary_to_term(") and not String.contains?(line, "[:safe]")
        end)
        |> Enum.map(fn {line, line_no} -> {path, line_no, String.trim(line)} end)
      end)

    assert matches == []
  end

  test "tagged AST binaries hydrate with safe decoding" do
    {:ok, ast} =
      Exograph.ElixirParser.string_to_quoted(
        "defmodule SafeHydrate do\n  def call, do: Repo.get!(User, 1)\nend"
      )

    binary = :erlang.term_to_binary(ast, [:compressed])

    assert :erlang.binary_to_term(binary, [:safe]) == ast
  end

  defp contains?(term, wanted) do
    term == wanted or
      cond do
        is_tuple(term) -> term |> Tuple.to_list() |> Enum.any?(&contains?(&1, wanted))
        is_list(term) -> Enum.any?(term, &contains?(&1, wanted))
        true -> false
      end
  end
end
