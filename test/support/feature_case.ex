defmodule Exograph.FeatureCase do
  @moduledoc false
  use ExUnit.CaseTemplate

  using do
    quote do
      use PhoenixTest.Playwright.Case, async: false
      import PhoenixTest
    end
  end

  setup_all _context do
    if Code.ensure_loaded?(PhoenixTest.Playwright.Supervisor) do
      case PhoenixTest.Playwright.Supervisor.start_link() do
        {:ok, _pid} -> :ok
        {:error, {:already_started, _pid}} -> :ok
      end
    end

    Exograph.Test.WebSetup.ensure_started!()
    Application.put_env(:phoenix_test, :base_url, Exograph.Test.WebSetup.base_url())
    :ok
  end
end
