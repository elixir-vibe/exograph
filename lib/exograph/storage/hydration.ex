defmodule Exograph.Storage.Hydration do
  @moduledoc """
  Converts storage records and joined file/version columns back into domain structs.
  """

  def fragment(
        record,
        source,
        path,
        package_version \\ nil,
        package_name \\ nil,
        file_ast \\ nil,
        locator \\ nil
      ) do
    locator = locator || file_ast |> decode_file_ast() |> Exograph.AST.Locator.index()
    fragment_ast = Exograph.AST.Locator.slice(locator, record.node_pre, record.node_post)

    record
    |> Map.put(:ast, fragment_ast)
    |> Map.put(:source, source)
    |> Map.put(:file, path)
    |> Map.put(:package_version, package_version)
    |> Exograph.Storage.FragmentRecord.to_fragment()
    |> Map.put(:package, package_name)
  end

  def decode_file_ast(ast), do: Exograph.AST.Codec.load(ast)
  def locator(ast), do: ast |> decode_file_ast() |> Exograph.AST.Locator.index()
end
