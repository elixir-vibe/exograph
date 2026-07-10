defmodule Exograph.IdentifierTokens do
  @moduledoc false

  @identifier ~r/[A-Za-z_][A-Za-z0-9_!?]*/

  def from_source(source) when is_binary(source) do
    Regex.scan(@identifier, source)
    |> List.flatten()
    |> Enum.flat_map(&tokens/1)
    |> Enum.uniq()
    |> Enum.join(" ")
  end

  defp tokens(identifier) do
    normalized =
      identifier
      |> String.trim_trailing("!")
      |> String.trim_trailing("?")
      |> String.replace(~r/([a-z0-9])([A-Z])/, "\\1 \\2")

    normalized
    |> String.split(~r/[^A-Za-z0-9]+/, trim: true)
    |> Enum.map(&String.downcase/1)
  end
end
