defmodule Exograph.Web.ResultFormatter do
  @moduledoc false

  alias Exograph.Web.SearchResult

  def format(results) when is_list(results) do
    results
    |> Enum.map(&SearchResult.from/1)
    |> Enum.group_by(&{&1.package, &1.package_version})
    |> Enum.sort_by(fn {{pkg, ver}, _} -> {pkg, ver || ""} end)
    |> Enum.map(fn {{package, package_version}, pkg_results} ->
      files =
        pkg_results
        |> Enum.group_by(& &1.file)
        |> Enum.sort_by(fn {file, _} -> file end)
        |> Enum.map(fn {file, file_results} ->
          %{
            file: file,
            source_url: hex_source_url(file_results),
            results:
              Enum.map(file_results, fn r ->
                %{r | preview: build_preview(r.source, r.fragment_line, r.line)}
              end)
          }
        end)

      %{
        key: package_key(package, package_version),
        package: package,
        package_version: package_version,
        package_url: hex_package_url(package, package_version),
        count: length(pkg_results),
        files: files
      }
    end)
  end

  def display_name(%{name: name, arity: arity}) when not is_nil(name) and not is_nil(arity),
    do: "#{name}/#{arity}"

  def display_name(%{name: name}) when not is_nil(name), do: name
  def display_name(_), do: nil

  def badge_class(:def), do: "bg-blue-900/40 text-blue-300"
  def badge_class(:defp), do: "bg-zinc-800 text-zinc-400"
  def badge_class(:defmacro), do: "bg-purple-900/40 text-purple-300"
  def badge_class(:defmacrop), do: "bg-purple-900/30 text-purple-400"
  def badge_class(:module), do: "bg-yellow-900/40 text-yellow-300"
  def badge_class(:expression), do: "bg-green-900/40 text-green-300"
  def badge_class(:definition), do: "bg-indigo-900/40 text-indigo-300"
  def badge_class(:reference), do: "bg-orange-900/40 text-orange-300"
  def badge_class(:call), do: "bg-teal-900/40 text-teal-300"
  def badge_class(_), do: "bg-zinc-800 text-zinc-400"

  defp hex_source_url([%{package: pkg, package_version: ver} | _]) when is_binary(ver),
    do: hex_package_url(pkg, ver)

  defp hex_source_url(_), do: nil

  defp hex_package_url(pkg, ver) when is_binary(ver), do: "https://hex.pm/packages/#{pkg}/#{ver}"
  defp hex_package_url(pkg, _ver), do: "https://hex.pm/packages/#{pkg}"

  defp package_key(package, nil), do: package
  defp package_key(package, version), do: "#{package}@#{version}"

  defp build_preview(nil, _, _), do: nil
  defp build_preview(_, _, nil), do: nil

  defp build_preview(source, _fragment_line, match_line)
       when is_binary(source) and is_integer(match_line) do
    Exograph.Web.Highlighter.highlight(source, match_line, 4)
  end

  defp build_preview(_, _, _), do: nil
end
