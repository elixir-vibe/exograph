defmodule Exograph.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children =
      if System.get_env("EXOGRAPH_WEB") in ["1", "true", "TRUE", "yes"] do
        [{Exograph.Web.Runtime, Exograph.Web.Runtime.env_options()}]
      else
        []
      end

    Supervisor.start_link(children, strategy: :one_for_one, name: Exograph.Supervisor)
  end
end
