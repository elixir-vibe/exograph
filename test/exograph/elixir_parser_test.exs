defmodule Exograph.ElixirParserTest do
  use ExUnit.Case, async: false

  test "existing static atom mode replaces unknown atoms without growing the atom table" do
    prefix = "exograph_parser_unknown_#{System.unique_integer([:positive])}"

    source = """
    defmodule #{Macro.camelize(prefix)} do
      @value :#{prefix}_literal
      def #{prefix}_function, do: @value
    end
    """

    before_count = :erlang.system_info(:atom_count)

    assert {:ok, ast} =
             Exograph.ElixirParser.string_to_quoted(source,
               line: 1,
               columns: true,
               static_atoms: :existing
             )

    after_count = :erlang.system_info(:atom_count)

    assert after_count == before_count
    assert Macro.to_string(ast) =~ "__exograph_unknown_atom__"
    assert_raise ArgumentError, fn -> String.to_existing_atom("#{prefix}_literal") end
    assert_raise ArgumentError, fn -> String.to_existing_atom("#{prefix}_function") end
  end

  test "create static atom mode preserves opt-in behavior" do
    name = "exograph_parser_created_#{System.unique_integer([:positive])}"
    source = ":#{name}"

    assert_raise ArgumentError, fn -> String.to_existing_atom(name) end
    assert {:ok, _ast} = Exograph.ElixirParser.string_to_quoted(source, static_atoms: :create)
    assert String.to_existing_atom(name) == String.to_atom(name)
  end
end
