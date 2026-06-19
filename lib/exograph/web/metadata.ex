defmodule Exograph.Web.Metadata do
  @moduledoc false

  @title "Exograph — Elixir code search"
  @description "Search Hex package source code with structural Elixir queries, text search, call graph facts, and package-aware results."
  @image_path "/social/exograph-card.png"
  @image_type "image/png"

  def page do
    public_url = public_url()

    %{
      title: @title,
      description: @description,
      site_name: Application.get_env(:exograph, :web_site_name, "Exograph"),
      canonical_url: public_url,
      image_url: absolute_url(public_url, @image_path),
      image_type: @image_type
    }
  end

  defp public_url do
    case Application.get_env(:exograph, :web_public_url) do
      url when is_binary(url) and url != "" -> ensure_trailing_slash(url)
      _other -> nil
    end
  end

  defp absolute_url(nil, _path), do: nil
  defp absolute_url(base_url, path), do: base_url |> URI.merge(path) |> URI.to_string()

  defp ensure_trailing_slash(url) do
    if String.ends_with?(url, "/"), do: url, else: url <> "/"
  end
end
