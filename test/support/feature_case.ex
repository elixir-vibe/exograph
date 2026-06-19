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
    Exograph.Test.WebSetup.ensure_started!()
    File.rm_rf!(Volt.Config.build().outdir)
    Mix.Task.rerun("volt.build")
    Application.put_env(:phoenix_test, :base_url, Exograph.Test.WebSetup.base_url())
    :ok
  end
end
