defmodule Exograph.Storage.Hydration do
  @moduledoc """
  Converts storage records and joined file/version columns back into domain structs.
  """

  def fragment(record, source, path, package_version \\ nil, package_name \\ nil, file_ast \\ nil) do
    file_ast = decode_file_ast(file_ast)

    record
    |> Map.put(:source, source)
    |> Map.put(:file, path)
    |> Map.put(:package_version, package_version)
    |> Exograph.Storage.FragmentRecord.to_fragment(file_ast)
    |> Map.put(:package, package_name)
  end

  defp decode_file_ast(nil), do: nil
  defp decode_file_ast(binary) when is_binary(binary), do: :erlang.binary_to_term(binary, [:safe])
  defp decode_file_ast(ast), do: ast
end
