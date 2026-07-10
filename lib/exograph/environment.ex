defmodule Exograph.Environment do
  @moduledoc false

  def get(name, default), do: System.get_env(name) || default

  def integer(name, default) do
    case System.get_env(name) do
      nil -> default
      "" -> default
      value -> String.to_integer(value)
    end
  end
end
