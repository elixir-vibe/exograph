defmodule Exograph.Storage.Schema.DSL do
  @moduledoc false

  defmacro table(name, record, do: block) do
    table_ast(name, record, [], block_indexes(block))
  end

  defmacro table(name, record, opts) do
    table_ast(name, record, opts, [])
  end

  defmacro table(name, record, opts, do: block) do
    table_ast(name, record, opts, block_indexes(block))
  end

  defmacro unique_index(fields, opts \\ []) do
    quote bind_quoted: [fields: fields, opts: opts] do
      %{fields: fields, name: Keyword.fetch!(opts, :name), unique?: true}
    end
  end

  defmacro index(fields, opts \\ []) do
    quote bind_quoted: [fields: fields, opts: opts] do
      %{fields: fields, name: Keyword.fetch!(opts, :name), unique?: false}
    end
  end

  defp table_ast(name, record, opts, indexes) do
    quote do
      %{
        name: unquote(name),
        record: unquote(record),
        primary_key?: Keyword.get(unquote(opts), :primary_key, true),
        indexes: [unquote_splicing(indexes)]
      }
    end
  end

  defp block_indexes({:__block__, _meta, indexes}), do: indexes
  defp block_indexes(index), do: [index]
end
