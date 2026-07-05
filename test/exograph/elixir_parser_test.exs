defmodule Exograph.ElixirParserTest do
  use ExUnit.Case, async: false

  alias Exograph.Ident

  defp id(name), do: Ident.tag(name)

  test "parser emits tagged identifiers and does not intern arbitrary source identifiers" do
    prefix = "exograph_parser_tagged_#{System.unique_integer([:positive])}"
    module = Macro.camelize(prefix)
    function = "#{prefix}_function"
    variable = "#{prefix}_variable"
    local_call = "#{prefix}_local_call"
    keyword = "#{prefix}_keyword"
    map_key = "#{prefix}_map_key"
    literal = "#{prefix}_literal"

    source = """
    defmodule #{module} do
      @value :#{literal}
      def #{function}(#{variable}) do
        %{#{map_key}: :#{literal}}
        #{local_call}(#{variable}, #{keyword}: :#{literal})
      end
    end
    """

    before_count = :erlang.system_info(:atom_count)

    assert {:ok, ast} = Exograph.ElixirParser.string_to_quoted(source, line: 1, columns: true)

    after_count = :erlang.system_info(:atom_count)
    assert after_count - before_count < 20

    assert contains?(ast, id(module))
    assert contains?(ast, id(function))
    assert contains?(ast, id(variable))
    assert contains?(ast, id(local_call))
    assert contains?(ast, id(keyword))
    assert contains?(ast, id(map_key))
    assert contains?(ast, id(literal))

    for name <- [module, function, variable, local_call, keyword, map_key, literal] do
      assert_raise ArgumentError, fn -> String.to_existing_atom(name) end
    end
  end

  test "parser preserves structural search shapes with tagged identifiers" do
    source = """
    defmodule MyApp.Server do
      alias MyApp.User
      @moduledoc false

      def handle_call(msg, from, state) do
        users = Repo.all(User)
        ids = Enum.map(users, & &1.id)
        %MyStruct{field: msg}
        {:reply, Repo.get!(User, msg.id), state}
      end
    end
    """

    assert {:ok, ast} = Exograph.ElixirParser.string_to_quoted(source, line: 1, columns: true)

    assert matches_any?(ast, "Repo.get!(_, _)")
    assert matches_any?(ast, "Enum.map(_, _)")
    assert matches_any?(ast, "def handle_call(_, _, _) do ... end")
    assert matches_any?(ast, "%MyStruct{field: _}")
    assert matches_any?(ast, "alias MyApp.User")
    assert matches_any?(ast, "@moduledoc _")
  end

  test "term binaries are deterministic regardless of previously existing atoms" do
    source = """
    defmodule DeterministicExample do
      def call(value), do: Repo.get!(User, value)
    end
    """

    assert {:ok, ast1} = Exograph.ElixirParser.string_to_quoted(source, line: 1, columns: true)

    _ = :persistent_term
    _ = Enum.map([:calendar, :crypto, :gen_tcp], &:code.ensure_loaded/1)

    assert {:ok, ast2} = Exograph.ElixirParser.string_to_quoted(source, line: 1, columns: true)

    assert :erlang.term_to_binary(ast1) == :erlang.term_to_binary(ast2)
  end

  test "template-like parse failures return errors instead of raising" do
    source = "{:ok, conn:<%= @arke_ns %>.ConnTest.build_conn()}"

    assert {:error, %ArgumentError{}} =
             Exograph.ElixirParser.string_to_quoted(source, line: 1, columns: true)

    assert [] = Exograph.Extractor.ExAST.index_source("template.ex", source)
  end

  test "legacy static_atoms options are ignored and remain atom-free" do
    name = "exograph_parser_ignored_option_#{System.unique_integer([:positive])}"
    source = ":#{name}"

    assert_raise ArgumentError, fn -> String.to_existing_atom(name) end

    for mode <- [:create, :existing, :indexed] do
      assert {:ok, ast} = Exograph.ElixirParser.string_to_quoted(source, static_atoms: mode)
      assert ast == id(name)
      assert_raise ArgumentError, fn -> String.to_existing_atom(name) end
    end
  end

  defp matches_any?(ast, pattern) do
    {_ast, matched?} =
      Macro.prewalk(ast, false, fn node, matched? ->
        matched? = matched? or match?({:ok, _}, ExAST.Pattern.match(node, pattern))
        {node, matched?}
      end)

    matched?
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
