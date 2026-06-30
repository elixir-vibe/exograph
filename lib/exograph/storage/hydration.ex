defmodule Exograph.Storage.Hydration do
  @moduledoc """
  Converts storage records and joined file/version columns back into domain structs.
  """

  def fragment(record, source, path, package_version \\ nil, package_name \\ nil) do
    record
    |> Map.put(:source, source)
    |> Map.put(:file, path)
    |> Map.put(:package_version, package_version)
    |> Exograph.Storage.FragmentRecord.to_fragment()
    |> Map.put(:package, package_name)
  end
end
