defmodule Exograph.Storage.Migrations.CreateSchema do
  @moduledoc """
  Ecto migration that creates the DuckDB-backed Exograph storage schema.
  """

  use Ecto.Migration

  alias Exograph.Storage.Schema

  def up do
    create_if_not_exists table(name(:index_format), table_opts(primary_key: false)) do
      add(:id, :integer, primary_key: true)
      add(:format_version, :integer, null: false)
      add(:parser_version, :integer, null: false)
    end

    create_indexes(:index_format)

    create_if_not_exists table(name(:packages), table_opts()) do
      add(:ecosystem, :text, null: false)
      add(:name, :text, null: false)
      add(:metadata, :map, null: false, default: %{})
      timestamps(type: :utc_datetime_usec)
    end

    create_indexes(:packages)

    create_if_not_exists table(name(:package_versions), table_opts()) do
      add(:package_id, :integer, null: false)
      add(:version, :text, null: false)
      add(:source_ref, :text)
      add(:checksum, :text)
      add(:index_state, :text, null: false, default: "pending")
      add(:metadata, :map, null: false, default: %{})
      timestamps(type: :utc_datetime_usec)
    end

    create_indexes(:package_versions)

    create_if_not_exists table(name(:files), table_opts(primary_key: false)) do
      add(:id, :serial)
      add(:package_id, :integer)
      add(:package_version_id, :integer)
      add(:path, :text, null: false)
      add(:source, :text, null: false)
      add(:ast, :binary)
      add(:comments_text, :text, null: false, default: "")
      add(:identifier_tokens, :text, null: false, default: "")
      add(:sha256, :text, null: false)
      timestamps(type: :utc_datetime_usec)
    end

    create_indexes(:files)

    create_if_not_exists table(name(:terms), table_opts(primary_key: false)) do
      add(:id, :serial)
      add(:term, :text, null: false)
    end

    create_indexes(:terms)

    create_if_not_exists table(name(:fragment_terms), table_opts(primary_key: false)) do
      add(:term_id, :integer, null: false)
      add(:fragment_id, :integer, null: false)
    end

    create_if_not_exists table(name(:fragments), table_opts(primary_key: false)) do
      add(:id, :serial)
      add(:package_id, :integer)
      add(:package_version_id, :integer)
      add(:file_id, :integer)
      add(:content_hash, :binary)
      add(:node_pre, :integer)
      add(:node_post, :integer)
      add(:kind, :text, null: false)
      add(:module, :text)
      add(:name, :text)
      add(:arity, :integer)
      add(:line, :integer, null: false)
      add(:end_line, :integer)
      add(:mass, :integer, null: false)
      add(:exact_hash, :binary)
      add(:sub_hashes, {:array, :bigint}, null: false, default: [])
      timestamps(type: :utc_datetime_usec)
    end

    create_indexes(:fragments)

    create_if_not_exists table(name(:comments), table_opts(primary_key: false)) do
      add(:id, :serial)
      add(:package_id, :integer)
      add(:package_version_id, :integer)
      add(:file_id, :integer, null: false)
      add(:fragment_id, :integer)
      add(:text, :text, null: false)
      add(:line, :integer)
      add(:column, :integer)
      timestamps(type: :utc_datetime_usec)
    end

    create_indexes(:comments)

    create_if_not_exists table(name(:definitions), table_opts(primary_key: false)) do
      add(:id, :serial)
      add(:package_id, :integer)
      add(:package_version_id, :integer)
      add(:file_id, :integer, null: false)
      add(:fragment_id, :integer)
      add(:kind, :text, null: false)
      add(:module, :text)
      add(:name, :text, null: false)
      add(:arity, :integer)
      add(:qualified_name, :text, null: false)
      add(:line, :integer)
      add(:column, :integer)
      timestamps(type: :utc_datetime_usec)
    end

    create_indexes(:definitions)

    create_if_not_exists table(name(:references), table_opts(primary_key: false)) do
      add(:id, :serial)
      add(:package_id, :integer)
      add(:package_version_id, :integer)
      add(:file_id, :integer, null: false)
      add(:fragment_id, :integer)
      add(:kind, :text, null: false)
      add(:module, :text)
      add(:name, :text, null: false)
      add(:arity, :integer)
      add(:qualified_name, :text, null: false)
      add(:line, :integer)
      add(:column, :integer)
      timestamps(type: :utc_datetime_usec)
    end

    create_indexes(:references)

    create_if_not_exists table(name(:graph_nodes), table_opts(primary_key: false)) do
      add(:id, :serial)
      add(:package_id, :integer)
      add(:package_version_id, :integer)
      add(:file_id, :integer)
      add(:fragment_id, :integer)
      add(:engine, :text, null: false)
      add(:external_id, :text)
      add(:kind, :text, null: false)
      add(:module, :text)
      add(:name, :text)
      add(:arity, :integer)
      add(:qualified_name, :text, null: false)
      add(:line, :integer)
      add(:column, :integer)
      add(:metadata, :map, null: false, default: %{})
      timestamps(type: :utc_datetime_usec)
    end

    create_indexes(:graph_nodes)

    create_if_not_exists table(name(:call_edges), table_opts(primary_key: false)) do
      add(:id, :serial)
      add(:package_id, :integer)
      add(:package_version_id, :integer)
      add(:file_id, :integer)

      add(:caller_node_id, :integer, null: false)
      add(:callee_node_id, :integer, null: false)

      add(:call_site_fragment_id, :integer)

      add(:caller_qualified_name, :text, null: false)
      add(:callee_qualified_name, :text, null: false)
      add(:line, :integer)
      add(:column, :integer)
      add(:metadata, :map, null: false, default: %{})
      timestamps(type: :utc_datetime_usec)
    end

    create_indexes(:call_edges)
  end

  def down do
    Schema.tables()
    |> Enum.reverse()
    |> Enum.each(fn table -> drop_if_exists(table(name(table.name))) end)
  end

  defp create_indexes(table) do
    table = Schema.table(table)

    Enum.each(table.indexes, fn index ->
      index_definition =
        if index.unique? do
          unique_index(name(table.name), index.fields, name: index_name(table.name, index.name))
        else
          index(name(table.name), index.fields, name: index_name(table.name, index.name))
        end

      create_index_if_not_deferred(index_definition)
    end)
  end

  defp create_index_if_not_deferred(index), do: create_if_not_exists(index)

  defp table_opts(opts \\ []), do: opts

  defp name(suffix), do: Schema.table_name(table_prefix(), suffix)
  defp index_name(table, suffix), do: Schema.index_name(table_prefix(), table, suffix)

  defp table_prefix do
    Application.fetch_env!(:exograph, __MODULE__)[:prefix]
  end
end
