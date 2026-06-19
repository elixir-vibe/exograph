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
    Application.put_env(:phoenix_test, :base_url, Exograph.Test.WebSetup.base_url())
    :ok
  end
end
