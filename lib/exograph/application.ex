defmodule Exograph.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    start_http_client!()

    children =
      if System.get_env("EXOGRAPH_WEB") in ["1", "true", "TRUE", "yes"] do
        [{Exograph.Web.Runtime, Exograph.Web.Runtime.env_options()}]
      else
        []
      end

    Supervisor.start_link(children, strategy: :one_for_one, name: Exograph.Supervisor)
  end

  defp start_http_client! do
    case :inets.start(:httpc, profile: :default) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
      {:error, reason} -> raise "failed to start :httpc default profile: #{inspect(reason)}"
    end
  end
end
