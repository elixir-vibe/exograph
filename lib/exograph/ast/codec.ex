defmodule Exograph.AST.Codec do
  @moduledoc false

  @atom_tag "__exograph_atom__"
  @tuple_tag "__exograph_tuple__"
  @map_tag "__exograph_map__"

  @spec dump(term()) :: binary()
  def dump(term) do
    term
    |> encode()
    |> :erlang.term_to_binary([:compressed])
  end

  @spec load(binary() | term()) :: term()
  def load(nil), do: nil

  def load(binary) when is_binary(binary) do
    binary
    |> :erlang.binary_to_term([:safe])
    |> decode()
  end

  def load(term), do: term

  defp encode(atom) when is_atom(atom), do: {@atom_tag, Atom.to_string(atom)}
  defp encode(tuple) when is_tuple(tuple), do: {@tuple_tag, tuple |> Tuple.to_list() |> encode()}
  defp encode(list) when is_list(list), do: Enum.map(list, &encode/1)

  defp encode(map) when is_map(map) do
    entries = Enum.map(map, fn {key, value} -> {encode(key), encode(value)} end)
    {@map_tag, entries}
  end

  defp encode(other), do: other

  defp decode({@atom_tag, "nil"}), do: nil
  defp decode({@atom_tag, "true"}), do: true
  defp decode({@atom_tag, "false"}), do: false

  defp decode({@atom_tag, name}) when is_binary(name) do
    String.to_atom(name)
  end

  defp decode({@tuple_tag, encoded}) do
    encoded
    |> decode()
    |> List.to_tuple()
  end

  defp decode({@map_tag, entries}) do
    Map.new(entries, fn {key, value} -> {decode(key), decode(value)} end)
  end

  defp decode(list) when is_list(list), do: Enum.map(list, &decode/1)
  defp decode(other), do: other
end
