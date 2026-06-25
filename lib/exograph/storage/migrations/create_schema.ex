defmodule Exograph.Storage.Migrations.CreateSchema do
  @moduledoc """
  Ecto migration that creates the DuckDB-backed Exograph storage schema.
  """

  use Ecto.Migration

  alias Exograph.Storage.Schema

  def up do
    create_if_not_exists table(name(:schema_migrations), table_opts(primary_key: false)) do
      add(:version, :bigint, primary_key: true)
    end

    create_if_not_exists table(name(:packages), table_opts()) do
      add(:ecosystem, :text, null: false)
      add(:name, :text, null: false)
      add(:metadata, :map, null: false, default: %{})
      timestamps(type: :utc_datetime_usec)
    end

    create_indexes(:packages)

    create_if_not_exists table(name(:package_versions), table_opts()) do
      add(:package_id, references(name(:packages), on_delete: :delete_all), null: false)
      add(:version, :text, null: false)
      add(:source_ref, :text)
      add(:checksum, :text)
      add(:metadata, :map, null: false, default: %{})
      timestamps(type: :utc_datetime_usec)
    end

    create_indexes(:package_versions)

    create_if_not_exists table(name(:files), table_opts()) do
      add(:package_id, references(name(:packages), on_delete: :delete_all))
      add(:package_version_id, references(name(:package_versions), on_delete: :delete_all))
      add(:path, :text, null: false)
      add(:source, :text, null: false)
      add(:comments_text, :text, null: false, default: "")
      add(:sha256, :text, null: false)
      timestamps(type: :utc_datetime_usec)
    end

    create_indexes(:files)

    create_if_not_exists table(name(:terms), table_opts(primary_key: false)) do
      add(:id, :serial, primary_key: true)
      add(:term, :text, null: false)
    end

    create_indexes(:terms)

    create_if_not_exists table(name(:fragment_terms), table_opts(primary_key: false)) do
      add(:term_id, :integer, null: false)
      add(:fragment_id, :integer, null: false)
    end

    create_if_not_exists table(name(:fragments), table_opts()) do
      add(:package_id, references(name(:packages), on_delete: :delete_all))
      add(:package_version_id, references(name(:package_versions), on_delete: :delete_all))
      add(:file_id, references(name(:files), on_delete: :delete_all))
      add(:content_hash, :binary)
      add(:ast, :binary, null: false)
      add(:kind, :text, null: false)
      add(:module, :text)
      add(:name, :text)
      add(:arity, :integer)
      add(:line, :integer, null: false)
      add(:end_line, :integer)
      add(:mass, :integer, null: false)
      add(:exact_hash, :binary)
      add(:terms, {:array, :integer}, null: false, default: [])
      add(:sub_hashes, {:array, :bigint}, null: false, default: [])
      timestamps(type: :utc_datetime_usec)
    end

    create_indexes(:fragments)

    create_if_not_exists table(name(:comments), table_opts()) do
      add(:package_id, references(name(:packages), on_delete: :delete_all))
      add(:package_version_id, references(name(:package_versions), on_delete: :delete_all))
      add(:file_id, references(name(:files), on_delete: :delete_all), null: false)
      add(:fragment_id, references(name(:fragments), on_delete: :nilify_all))
      add(:text, :text, null: false)
      add(:line, :integer)
      add(:column, :integer)
      timestamps(type: :utc_datetime_usec)
    end

    create_indexes(:comments)

    create_if_not_exists table(name(:definitions), table_opts()) do
      add(:package_id, references(name(:packages), on_delete: :delete_all))
      add(:package_version_id, references(name(:package_versions), on_delete: :delete_all))
      add(:file_id, references(name(:files), on_delete: :delete_all), null: false)
      add(:fragment_id, references(name(:fragments), on_delete: :nilify_all))
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

    create_if_not_exists table(name(:references), table_opts()) do
      add(:package_id, references(name(:packages), on_delete: :delete_all))
      add(:package_version_id, references(name(:package_versions), on_delete: :delete_all))
      add(:file_id, references(name(:files), on_delete: :delete_all), null: false)
      add(:fragment_id, references(name(:fragments), on_delete: :nilify_all))
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

    create_if_not_exists table(name(:graph_nodes), table_opts()) do
      add(:package_id, references(name(:packages), on_delete: :delete_all))
      add(:package_version_id, references(name(:package_versions), on_delete: :delete_all))
      add(:file_id, references(name(:files), on_delete: :delete_all))
      add(:fragment_id, references(name(:fragments), on_delete: :nilify_all))
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

    create_if_not_exists table(name(:call_edges), table_opts()) do
      add(:package_id, references(name(:packages), on_delete: :delete_all))
      add(:package_version_id, references(name(:package_versions), on_delete: :delete_all))
      add(:file_id, references(name(:files), on_delete: :delete_all))

      add(:caller_node_id, references(name(:graph_nodes), on_delete: :delete_all), null: false)
      add(:callee_node_id, references(name(:graph_nodes), on_delete: :delete_all), null: false)

      add(:call_site_fragment_id, references(name(:fragments), on_delete: :nilify_all))

      add(:caller_qualified_name, :text, null: false)
      add(:callee_qualified_name, :text, null: false)
      add(:line, :integer)
      add(:column, :integer)
      add(:metadata, :map, null: false, default: %{})
      timestamps(type: :utc_datetime_usec)
    end

    create_indexes(:call_edges)

    create_if_not_exists table(name(:tree_nodes), table_opts(primary_key: false)) do
      add(:fragment_id, references(name(:fragments), on_delete: :delete_all),
        null: false,
        primary_key: true
      )

      add(:id, :integer, null: false, primary_key: true)
      add(:parent_id, :integer)
      add(:ordinal, :integer, null: false)
      add(:role, :text)
      add(:kind, :text, null: false)
      add(:label, :text)
      add(:line, :integer, null: false)
      add(:preorder, :integer, null: false)
      add(:postorder, :integer, null: false)
      add(:depth, :integer, null: false)
    end

    create_indexes(:tree_nodes)
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
