defmodule Exograph.Web.Router do
  @moduledoc false
  use Phoenix.Router
  import Phoenix.LiveView.Router

  pipeline :browser do
    plug(:accepts, ["html"])
    plug(:fetch_session)
    plug(:fetch_live_flash)
    plug(:put_root_layout, html: {Exograph.Web.Layouts, :root})
    plug(:protect_from_forgery)
    plug(:put_secure_browser_headers)
  end

  pipeline :api do
    plug(:accepts, ["json"])
    plug(Exograph.Web.Plugs.RateLimit, limit: 60, scale: :timer.minutes(1))
  end

  scope "/", Exograph.Web do
    pipe_through(:browser)
    live("/", QueryLive, :index)
    live("/progress", ProgressLive, :index)
  end

  scope "/api", Exograph.Web do
    pipe_through(:api)

    post("/search", APIController, :search)
    post("/query", APIController, :query)
    post("/plan", APIController, :plan)
    post("/hydrate", APIController, :hydrate)
    get("/capabilities", APIController, :capabilities)
    get("/health", APIController, :health)
    get("/packages", APIController, :packages)
    get("/stats", APIController, :stats)
  end
end
