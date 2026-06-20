defmodule Mix.Tasks.Exograph.ReleaseArtifact do
  @moduledoc """
  Builds an Exograph OTP release artifact.

      MIX_ENV=prod mix exograph.release_artifact --out-dir /srv/artifacts/exograph

  Exograph owns its frontend prebuild steps. ReleaseKit owns the generic OTP
  release tarball and manifest format.
  """

  use Mix.Task

  @shortdoc "Builds a ReleaseKit-compatible Exograph release artifact"

  @impl true
  def run(args) do
    {opts, rest, invalid} =
      OptionParser.parse(args,
        strict: [
          out_dir: :string,
          version: :string,
          port: :integer,
          health_path: :string
        ]
      )

    if invalid != [], do: Mix.raise("Invalid options: #{inspect(invalid)}")
    if rest != [], do: Mix.raise("Unexpected arguments: #{inspect(rest)}")

    port = Keyword.get(opts, :port, 4_200)
    health_path = Keyword.get(opts, :health_path, "/")

    build_assets!()

    result =
      ReleaseKit.build_artifact(
        out_dir: Keyword.get(opts, :out_dir),
        version: Keyword.get(opts, :version),
        port: port,
        health_path: health_path,
        env_clear: %{
          "EXOGRAPH_WEB" => "true",
          "EXOGRAPH_PORT" => to_string(port),
          "RELEASE_DISTRIBUTION" => "none"
        }
      )

    Mix.shell().info("Release tarball: #{result.tarball}")
    Mix.shell().info("ReleaseKit manifest: #{result.manifest_path}")
  end

  defp build_assets! do
    Application.ensure_all_started(:req)
    File.cd!("assets", fn -> NPM.install(production: true, frozen: true) end)
    File.rm_rf!(Volt.Config.build().outdir)
    Mix.Task.run("volt.build")
  end
end
