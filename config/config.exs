import Config

config :volt,
  entry: "assets/web/app.ts",
  root: "assets",
  outdir: "priv/static/assets",
  target: :es2020,
  hash: false,
  asset_url_prefix: "/assets/js",
  resolve_dirs: ["assets/node_modules", "deps"],
  module_types: %{".css" => :empty, ".ttf" => :asset},
  tailwind: [
    css: "assets/web/app.css",
    sources: [
      %{base: "lib/", pattern: "**/*.{ex,heex}"},
      %{base: "assets/", pattern: "**/*.{ts,css}"}
    ]
  ]

config :volt, :server,
  prefix: "/assets",
  watch_dirs: ["lib/", "assets/"]

config :phoenix, :json_library, Jason

config :exograph, Exograph.Web.Endpoint, code_reloader: false

if Mix.env() == :test do
  config :phoenix_test,
    otp_app: :exograph,
    playwright: [
      browser: :chromium,
      headless: true,
      browser_launch_timeout: 30_000,
      timeout: 5_000
    ]
end
