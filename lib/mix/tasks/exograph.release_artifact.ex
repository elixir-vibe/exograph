defmodule Mix.Tasks.Exograph.ReleaseArtifact do
  @moduledoc """
  Builds an Exograph OTP release tarball and HostKit OTP-release manifest.

      MIX_ENV=prod mix exograph.release_artifact --out-dir /srv/artifacts/exograph

  """
  use Mix.Task

  @shortdoc "Builds a HostKit-consumable Exograph release artifact"

  @impl true
  def run(args) do
    {opts, _rest, invalid} =
      OptionParser.parse(args,
        strict: [
          out_dir: :string,
          version: :string,
          port: :integer,
          health_path: :string
        ]
      )

    if invalid != [], do: Mix.raise("Invalid options: #{inspect(invalid)}")

    out_dir =
      opts
      |> Keyword.get(:out_dir, Path.join(Mix.Project.build_path(), "artifacts"))
      |> Path.expand()

    version = Keyword.get(opts, :version, artifact_version())
    port = Keyword.get(opts, :port, 4_200)
    health_path = Keyword.get(opts, :health_path, "/")

    File.mkdir_p!(out_dir)
    build_assets!()
    Mix.Task.run("compile")
    Mix.Task.run("release", ["--overwrite"])

    release_name = Atom.to_string(Mix.Project.config()[:app])
    release_dir = Path.join([Mix.Project.build_path(), "rel", release_name])
    tarball = Path.join(out_dir, "#{release_name}-#{version}.tar.gz")
    manifest_path = Path.join(out_dir, "#{release_name}.etf")

    create_tarball!(release_dir, tarball)
    write_manifest!(manifest_path, release_name, version, tarball, port, health_path)

    Mix.shell().info("Release tarball: #{tarball}")
    Mix.shell().info("HostKit manifest: #{manifest_path}")
  end

  defp build_assets! do
    Application.ensure_all_started(:req)
    File.cd!("assets", fn -> NPM.install(production: true, frozen: true) end)
    Exograph.Web.Monaco.ensure_bundled!()
    Mix.Task.run("volt.build")
  end

  defp create_tarball!(release_dir, tarball) do
    files =
      release_dir
      |> recursive_files()
      |> Enum.map(&String.to_charlist/1)

    File.rm(tarball)

    File.cd!(release_dir, fn ->
      :ok = :erl_tar.create(String.to_charlist(tarball), files, [:compressed])
    end)
  end

  defp recursive_files(root) do
    root
    |> Path.join("**/*")
    |> Path.wildcard(match_dot: true)
    |> Enum.reject(&File.dir?/1)
    |> Enum.map(&Path.relative_to(&1, root))
  end

  defp write_manifest!(path, release_name, version, tarball, port, health_path) do
    manifest = %{
      tool: "exograph",
      format: :beam_release_artifact,
      format_version: 1,
      app: release_name,
      version: version,
      release: release_name,
      mix_env: "prod",
      tarball: tarball,
      runtime: %{command: ["bin/#{release_name}", "start"]},
      env: %{
        clear: %{
          "EXOGRAPH_WEB" => "true",
          "EXOGRAPH_PORT" => to_string(port),
          "RELEASE_DISTRIBUTION" => "none"
        },
        secret: []
      },
      health_check: %{
        path: health_path,
        port: port,
        url: "http://127.0.0.1:#{port}#{health_path}"
      }
    }

    File.write!(path, :erlang.term_to_binary(manifest))
  end

  defp artifact_version do
    date = Date.utc_today() |> Date.to_iso8601(:basic)

    revision =
      case System.cmd("git", ["rev-parse", "--short", "HEAD"], stderr_to_stdout: true) do
        {sha, 0} -> String.trim(sha)
        _other -> Mix.Project.config()[:version]
      end

    "#{date}-#{revision}"
  end
end
