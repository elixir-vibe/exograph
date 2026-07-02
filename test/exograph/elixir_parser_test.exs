defmodule Exograph.ElixirParserTest do
  use ExUnit.Case, async: false

  test "indexed static atom mode preserves structural identifiers without interning atom payloads" do
    prefix = "exograph_parser_indexed_#{System.unique_integer([:positive])}"
    module = Module.concat([Macro.camelize(prefix)])
    function = "#{prefix}_function"
    variable = "#{prefix}_variable"
    local_call = "#{prefix}_local_call"
    keyword = "#{prefix}_keyword"
    map_key = "#{prefix}_map_key"
    literal = "#{prefix}_literal"

    source = """
    defmodule #{inspect(module)} do
      @value :#{literal}
      def #{function}(#{variable}) do
        %{#{map_key}: :#{literal}}
        #{local_call} #{variable}, #{keyword}: :#{literal}
      end
    end
    """

    assert {:ok, ast} =
             Exograph.ElixirParser.string_to_quoted(source,
               line: 1,
               columns: true,
               static_atoms: :indexed
             )

    rendered = Macro.to_string(ast)
    assert rendered =~ inspect(module)
    assert rendered =~ function
    assert rendered =~ variable
    assert rendered =~ local_call
    assert rendered =~ "__exograph_unknown_atom__"
    assert_raise ArgumentError, fn -> String.to_existing_atom(keyword) end
    assert_raise ArgumentError, fn -> String.to_existing_atom(map_key) end
    assert_raise ArgumentError, fn -> String.to_existing_atom(literal) end
  end

  test "indexed static atom mode preserves definitions whose first argument is an atom literal" do
    prefix = "exograph_parser_atom_arg_#{System.unique_integer([:positive])}"
    function = "#{prefix}_function"
    literal = "#{prefix}_literal"

    source = """
    def #{function}(:#{literal}) do
      :ok
    end
    """

    assert {:ok, ast} =
             Exograph.ElixirParser.string_to_quoted(source,
               line: 1,
               columns: true,
               static_atoms: :indexed
             )

    rendered = Macro.to_string(ast)
    assert rendered =~ function
    assert rendered =~ "__exograph_unknown_atom__"
    assert_raise ArgumentError, fn -> String.to_existing_atom(literal) end
  end

  test "indexed static atom mode preserves common structural search shapes" do
    prefix = "exograph_parser_shapes_#{System.unique_integer([:positive])}"
    module = Module.concat([Macro.camelize(prefix)])

    source = """
    defmodule #{inspect(module)} do
      def handle_call(msg, from, state) do
        users = Repo.all(User)
        ids = Enum.map(users, & &1.id)
        {:reply, Repo.get!(User, msg.id), state}
      end
    end
    """

    assert {:ok, ast} =
             Exograph.ElixirParser.string_to_quoted(source,
               line: 1,
               columns: true,
               static_atoms: :indexed
             )

    rendered = Macro.to_string(ast)
    assert rendered =~ inspect(module)
    assert rendered =~ "handle_call(msg, from, state)"
    assert rendered =~ "Repo.all(User)"
    assert rendered =~ "Enum.map(users"
    assert rendered =~ "Repo.get!(User, msg.id)"
  end

  test "existing static atom mode remains an explicit lossy legacy mode" do
    prefix = "exograph_parser_unknown_#{System.unique_integer([:positive])}"

    source = """
    defmodule #{Macro.camelize(prefix)} do
      @value :#{prefix}_literal
      def #{prefix}_function, do: @value
    end
    """

    assert {:ok, ast} =
             Exograph.ElixirParser.string_to_quoted(source,
               line: 1,
               columns: true,
               static_atoms: :existing
             )

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
