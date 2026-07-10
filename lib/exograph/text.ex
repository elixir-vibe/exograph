defmodule Exograph.Text do
  @moduledoc false

  @spec trigrams(String.t()) :: MapSet.t(String.t())
  def trigrams(text) when is_binary(text) do
    text
    |> String.graphemes()
    |> Enum.chunk_every(3, 1, :discard)
    |> Enum.map(&Enum.join/1)
    |> MapSet.new()
  end

  @spec literal_match?(String.t(), String.t()) :: boolean()
  def literal_match?(source, literal), do: String.contains?(source, literal)

  @spec regex_match?(String.t(), Regex.t()) :: boolean()
  def regex_match?(source, %Regex{} = regex), do: Regex.match?(regex, source)

  @spec literal_locations(String.t(), String.t()) :: [
          %{line: pos_integer(), column: pos_integer()}
        ]
  def literal_locations(source, literal) when is_binary(source) and is_binary(literal) do
    source
    |> :binary.matches(literal)
    |> Enum.map(&location(source, &1))
  end

  @spec regex_locations(String.t(), Regex.t()) :: [%{line: pos_integer(), column: pos_integer()}]
  def regex_locations(source, %Regex{} = regex) do
    regex
    |> Regex.scan(source, return: :index)
    |> Enum.map(fn [match | _captures] -> location(source, match) end)
  end

  defp location(source, {offset, _length}) do
    {line, column} =
      source
      |> binary_part(0, offset)
      |> String.split("\n")
      |> then(fn lines -> {length(lines), String.length(List.last(lines)) + 1} end)

    %{line: line, column: column}
  end
end
