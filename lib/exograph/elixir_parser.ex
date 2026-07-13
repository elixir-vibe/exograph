defmodule Exograph.ElixirParser do
  @moduledoc false

  alias Exograph.Ident

  def string_to_quoted(source, opts \\ []) do
    Code.string_to_quoted(source, parser_opts(opts))
  rescue
    exception in ArgumentError -> {:error, exception}
  end

  def string_to_quoted!(source, opts \\ []) do
    Code.string_to_quoted!(source, parser_opts(opts))
  end

  def string_to_quoted_with_comments(source, opts \\ []) do
    Code.string_to_quoted_with_comments(source, parser_opts(opts))
  rescue
    exception in ArgumentError -> {:error, exception}
  end

  defp parser_opts(opts) do
    opts
    |> Keyword.delete(:static_atoms)
    |> Keyword.put(:static_atoms_encoder, &tagged_ident/2)
  end

  defp tagged_ident(name, _metadata), do: {:ok, Ident.static_atom(name)}
end
