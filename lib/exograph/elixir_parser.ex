defmodule Exograph.ElixirParser do
  @moduledoc false

  @unknown_atom :__exograph_unknown_atom__

  def string_to_quoted(source, opts \\ []) do
    Code.string_to_quoted(source, parser_opts(source, opts))
  end

  def string_to_quoted_with_comments(source, opts \\ []) do
    Code.string_to_quoted_with_comments(source, parser_opts(source, opts))
  end

  defp parser_opts(source, opts) do
    case Keyword.get(opts, :static_atoms, :indexed) do
      :create ->
        Keyword.delete(opts, :static_atoms)

      :existing ->
        opts
        |> Keyword.delete(:static_atoms)
        |> Keyword.put_new(:static_atoms_encoder, &existing_atom/2)

      :indexed ->
        lines = String.split(source, "\n", trim: false)

        opts
        |> Keyword.delete(:static_atoms)
        |> Keyword.put_new(:static_atoms_encoder, &indexed_atom(&1, &2, lines))
    end
  end

  defp existing_atom(name, _metadata) do
    {:ok, String.to_existing_atom(name)}
  rescue
    ArgumentError -> {:ok, @unknown_atom}
  end

  defp indexed_atom(name, metadata, lines) do
    {:ok, String.to_existing_atom(name)}
  rescue
    ArgumentError ->
      if index_identifier_atom?(name, metadata, lines) do
        {:ok, String.to_atom(name)}
      else
        {:ok, @unknown_atom}
      end
  end

  defp index_identifier_atom?(name, metadata, lines) do
    line = metadata[:line]
    column = metadata[:column]

    if is_integer(line) and is_integer(column) do
      line = line_text(lines, line)
      current = current_character(line, column)
      previous = previous_character(line, column)
      following = following_nonspace(line, column - 1 + String.length(name))

      current != ?: and previous != ?: and following != ?:
    else
      false
    end
  end

  defp line_text(lines, line), do: Enum.at(lines, line - 1, "")

  defp current_character(line, column) do
    case String.slice(line, max(column - 1, 0), 1) do
      <<char::utf8>> -> char
      _ -> nil
    end
  end

  defp previous_character(line, column) do
    case String.slice(line, max(column - 2, 0), 1) do
      <<char::utf8>> -> char
      _ -> nil
    end
  end

  defp following_nonspace(line, offset) do
    line
    |> String.slice(offset..-1//1)
    |> String.to_charlist()
    |> Enum.find(&(&1 not in [?\s, ?\t]))
  end
end
