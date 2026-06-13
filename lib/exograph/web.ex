defmodule Exograph.Web do
  @moduledoc false

  @static_paths ~w(assets)

  def static_paths, do: @static_paths

  defmacro __using__(which) when is_atom(which) do
    apply(__MODULE__, which, [])
  end

  def html do
    quote do
      use Phoenix.Component
      import Phoenix.Controller, only: [get_csrf_token: 0]

      unquote(html_helpers())
    end
  end

  def live_view do
    quote do
      use Phoenix.LiveView
      unquote(html_helpers())
    end
  end

  defp html_helpers do
    quote do
      import Phoenix.HTML
      import Exograph.Web, only: [icon: 1]
      alias Phoenix.LiveView.JS
      unquote(verified_routes())
    end
  end

  use Phoenix.Component

  attr(:name, :string, required: true)
  attr(:class, :string, default: nil)
  attr(:rest, :global)

  def icon(assigns) do
    if Code.ensure_loaded?(PhoenixIconify) do
      apply(PhoenixIconify, :icon, [assigns])
    else
      assigns = Phoenix.Component.assign_new(assigns, :class, fn -> nil end)

      ~H"""
      <span class={@class} aria-hidden="true" data-icon={@name} {@rest}></span>
      """
    end
  end

  defp verified_routes do
    quote do
      use Phoenix.VerifiedRoutes,
        endpoint: Exograph.Web.Endpoint,
        router: Exograph.Web.Router,
        statics: Exograph.Web.static_paths()
    end
  end
end
