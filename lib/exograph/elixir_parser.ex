defmodule Exograph.ElixirParser do
  @moduledoc false

  @unknown_atom :__exograph_unknown_atom__

  def string_to_quoted(source, opts \\ []) do
    Code.string_to_quoted(source, parser_opts(opts))
  end

  def string_to_quoted_with_comments(source, opts \\ []) do
    Code.string_to_quoted_with_comments(source, parser_opts(opts))
  end

  defp parser_opts(opts) do
    case Keyword.get(opts, :static_atoms, :existing) do
      :create ->
        Keyword.delete(opts, :static_atoms)

      :existing ->
        opts
        |> Keyword.delete(:static_atoms)
        |> Keyword.put_new(:static_atoms_encoder, &safe_atom/2)
    end
  end

  defp safe_atom(name, _metadata) do
    {:ok, String.to_existing_atom(name)}
  rescue
    ArgumentError -> {:ok, @unknown_atom}
  end
end
