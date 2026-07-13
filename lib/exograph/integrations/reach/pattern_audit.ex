defmodule Exograph.Integrations.Reach.PatternAudit do
  @moduledoc "Reach adapter for Exograph's generic indexed pattern audit."

  alias Exograph.Integrations.Reach.Patterns

  def scan(index, modules, opts \\ []) do
    Exograph.PatternAudit.scan_patterns(index, Patterns.load!(modules), opts)
  end

  def load_patterns!(modules), do: Patterns.load!(modules)
  defdelegate scan_patterns(index, patterns, opts \\ []), to: Exograph.PatternAudit
end
