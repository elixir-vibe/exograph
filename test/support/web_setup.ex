defmodule Exograph.Test.WebSetup do
  @moduledoc false

  @port 4202

  def ensure_started! do
    if Process.whereis(Exograph.Web.Endpoint) do
      :already_started
    else
      start!()
    end
  end

  def base_url, do: "http://localhost:#{@port}"

  def assert_assets_built! do
    required = [
      "priv/static/assets/css/app.css",
      "priv/static/assets/css/manifest.json",
      "priv/static/assets/js/client.css",
      "priv/static/assets/js/client.js",
      "priv/static/assets/js/manifest.json"
    ]

    missing = Enum.reject(required, &File.regular?/1)
    codicons = Path.wildcard("priv/static/assets/js/codicon-*.ttf")

    cond do
      missing != [] ->
        raise "Feature tests require built frontend assets. Run `mix volt.build` first. Missing: #{Enum.join(missing, ", ")}"

      codicons == [] ->
        raise "Feature tests require built Monaco font assets. Run `mix volt.build` first. Missing: priv/static/assets/js/codicon-*.ttf"

      true ->
        :ok
    end
  end

  defp start! do
    assert_assets_built!()

    prefix = System.get_env("EXOGRAPH_PREFIX", "feature")

    repo_opts =
      case System.get_env("EXOGRAPH_DUCKDB_DATABASE") do
        nil -> []
        database -> [database: database]
      end

    Exograph.DuckDBSupport.start_managed_repo!(repo_opts)

    {:ok, index} =
      Exograph.index(feature_sources(),
        repo: Exograph.DuckDBRepo,
        prefix: prefix,
        migrate?: true,
        bm25?: false,
        min_mass: 4,
        package_version: [ecosystem: :hex, name: "feature_fixture", version: "1.0.0"]
      )

    Application.put_env(:exograph, :web_index, index)
    Application.put_env(:exograph, :web_repo, Exograph.DuckDBRepo)
    Application.put_env(:exograph, :web_prefix, prefix)

    endpoint_config = [
      adapter: Bandit.PhoenixAdapter,
      http: [ip: {127, 0, 0, 1}, port: @port],
      url: [host: "localhost", port: @port],
      server: true,
      secret_key_base: :crypto.strong_rand_bytes(64) |> Base.encode64(),
      live_view: [signing_salt: :crypto.strong_rand_bytes(8) |> Base.encode64()],
      pubsub_server: Exograph.Web.PubSub,
      render_errors: [
        formats: [html: Exograph.Web.ErrorHTML, json: Exograph.Web.ErrorJSON],
        layout: false
      ],
      check_origin: false
    ]

    Application.put_env(:exograph, Exograph.Web.Endpoint, endpoint_config)

    unless Process.whereis(Exograph.Web.PubSub) do
      {:ok, _} =
        Supervisor.start_link([{Phoenix.PubSub, name: Exograph.Web.PubSub}],
          strategy: :one_for_one
        )
    end

    if Code.ensure_loaded?(Exograph.Web.RateLimiter) do
      case Exograph.Web.RateLimiter.start_link([]) do
        {:ok, _} -> :ok
        {:error, {:already_started, _}} -> :ok
      end
    end

    {:ok, _} = Exograph.Web.Endpoint.start_link()
    :started
  end

  defp feature_sources do
    dir = Path.join(System.tmp_dir!(), "exograph-feature-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    path = Path.join(dir, "server.ex")

    File.write!(path, """
    defmodule FeatureFixture.Server do
      def handle_call(:get, _from, state) do
        {:reply, state, state}
      end

      def list(items) do
        Enum.map(items, &to_string/1)
      end

      def get_user(repo, id) do
        repo.get!(User, id)
      end

      def bang!(value) do
        value
      end
    end
    """)

    [path]
  end
end
