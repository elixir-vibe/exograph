defmodule Exograph.Storage.Schema.DSL do
  @moduledoc false

  defmacro table(name, record, opts \\ []) do
    quote bind_quoted: [name: name, record: record, opts: opts] do
      %{
        name: name,
        record: record,
        primary_key?: Keyword.get(opts, :primary_key, true)
      }
    end
  end
end
