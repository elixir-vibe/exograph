defmodule Exograph.AST.CodecTest do
  use ExUnit.Case, async: true

  alias Exograph.Ident

  test "persisted representation contains no atoms" do
    ast =
      {:defmodule, [line: 1],
       [
         {:__aliases__, [line: 1], [{:__exograph_ident__, "VeryUniqueModule"}]},
         [
           do:
             {:def, [line: 2],
              [{{:__exograph_ident__, "call"}, [line: 2], nil}, [do: Ident.tag("ok")]]}
         ]
       ]}

    encoded = Exograph.AST.Codec.dump(ast)
    external = :erlang.binary_to_term(encoded, [:safe])

    refute contains_atom?(external)
    assert Exograph.AST.Codec.load(encoded) == ast
  end

  test "loading tagged identifiers does not intern identifier names" do
    name = "DefinitelyNotAnExistingAtom#{System.unique_integer([:positive])}"
    ast = {{:__exograph_ident__, name}, [], nil}
    encoded = Exograph.AST.Codec.dump(ast)

    assert :error = try_existing_atom(name)
    assert Exograph.AST.Codec.load(encoded) == ast
    assert :error = try_existing_atom(name)
  end

  test "decodes non-structural atoms as tagged identifiers without interning them" do
    name = "DefinitelyNotAnExistingAtom#{System.unique_integer([:positive])}"
    encoded = :erlang.term_to_binary({"__exograph_atom__", name})

    assert :error = try_existing_atom(name)
    assert Exograph.AST.Codec.load(encoded) == Ident.tag(name)
    assert :error = try_existing_atom(name)
  end

  test "hydrates parser-generated sigil names in a fresh atom state" do
    {:ok, ast} = Exograph.ElixirParser.string_to_quoted("def render(assigns), do: ~H\"<p />\"")
    encoded = Exograph.AST.Codec.dump(ast)

    assert {:def, meta, _arguments} = hydrated = Exograph.AST.Codec.load(encoded)
    assert is_integer(meta[:line])
    assert contains?(hydrated, Ident.tag("sigil_H"))
  end

  defp contains_atom?(term) when is_atom(term), do: true

  defp contains_atom?(term) when is_tuple(term) do
    term
    |> Tuple.to_list()
    |> Enum.any?(&contains_atom?/1)
  end

  defp contains_atom?(term) when is_list(term), do: Enum.any?(term, &contains_atom?/1)

  defp contains_atom?(term) when is_map(term) do
    Enum.any?(term, fn {key, value} -> contains_atom?(key) or contains_atom?(value) end)
  end

  defp contains_atom?(_term), do: false

  defp contains?(term, wanted) do
    term == wanted or
      cond do
        is_tuple(term) -> term |> Tuple.to_list() |> Enum.any?(&contains?(&1, wanted))
        is_list(term) -> Enum.any?(term, &contains?(&1, wanted))
        true -> false
      end
  end

  defp try_existing_atom(name) do
    {:ok, String.to_existing_atom(name)}
  rescue
    ArgumentError -> :error
  end
end
