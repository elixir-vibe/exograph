defmodule Exograph.PatternParser do
  @moduledoc false

  def parse!(pattern) when is_binary(pattern) do
    Exograph.ElixirParser.string_to_quoted!(pattern)
  end
end
