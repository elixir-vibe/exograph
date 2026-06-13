defmodule Exograph.Web.Monaco do
  @moduledoc false

  @app_root Path.expand("../../..", __DIR__)
  @entry Path.join(@app_root, "assets/node_modules/monaco-editor/esm/vs/editor/edcore.main.js")
  @css_src Path.join(@app_root, "assets/node_modules/monaco-editor/min/vs/editor/editor.main.css")

  def ensure_bundled! do
    outdir = Volt.Config.build().outdir |> to_string()
    vendor_dir = Path.join(outdir, "vendor")

    bundle_js!(vendor_dir)
    copy_css!(vendor_dir)
  end

  defp bundle_js!(vendor_dir) do
    path = Path.join(vendor_dir, "monaco.js")

    if File.regular?(path) do
      :ok
    else
      File.mkdir_p!(vendor_dir)

      case OXC.bundle(@entry,
             cwd: @app_root,
             format: :esm,
             modules: [Path.join(@app_root, "assets/node_modules")],
             module_types: Volt.Config.build().module_types,
             define: %{"process.env.NODE_ENV" => ~s("production")}
           ) do
        {:ok, code} when is_binary(code) ->
          File.write!(path, code)
          {:ok, byte_size(code)}

        {:error, errors} ->
          {:error, errors}
      end
    end
  end

  defp copy_css!(vendor_dir) do
    path = Path.join(vendor_dir, "monaco.css")

    unless File.regular?(path) do
      File.mkdir_p!(vendor_dir)
      if File.regular?(@css_src), do: File.cp!(@css_src, path)
    end
  end
end
