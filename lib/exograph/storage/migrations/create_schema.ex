defmodule Exograph.Storage.Migrations.CreateSchema do
  @moduledoc false

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

    create_if_not_exists(
      unique_index(name(:packages), [:ecosystem, :name],
        name: index_name(:packages, "ecosystem_name")
      )
    )

    create_if_not_exists table(name(:package_versions), table_opts()) do
      add(:package_id, references(name(:packages), on_delete: :delete_all), null: false)
      add(:version, :text, null: false)
      add(:source_ref, :text)
      add(:checksum, :text)
      add(:metadata, :map, null: false, default: %{})
      timestamps(type: :utc_datetime_usec)
    end

    create_if_not_exists(
      unique_index(name(:package_versions), [:package_id, :version],
        name: index_name(:package_versions, "package_version")
      )
    )

    create_if_not_exists table(name(:files), table_opts()) do
      add(:package_id, references(name(:packages), on_delete: :delete_all))
      add(:package_version_id, references(name(:package_versions), on_delete: :delete_all))
      add(:path, :text, null: false)
      add(:source, :text, null: false)
      add(:comments_text, :text, null: false, default: "")
      add(:sha256, :text, null: false)
      timestamps(type: :utc_datetime_usec)
    end

    create_index_if_not_deferred(
      index(name(:files), [:package_version_id, :path], name: index_name(:files, "package_path"))
    )

    create_if_not_exists(
      unique_index(name(:files), [:package_version_id, :sha256],
        name: index_name(:files, "package_version_sha256")
      )
    )

    create_if_not_exists table(name(:terms), table_opts(primary_key: false)) do
      add(:id, :serial, primary_key: true)
      add(:term, :text, null: false)
    end

    create_if_not_exists(unique_index(name(:terms), [:term], name: index_name(:terms, "term")))

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

    create_if_not_exists(
      unique_index(name(:fragments), [:content_hash],
        name: index_name(:fragments, "content_hash")
      )
    )

    create_index_if_not_deferred(
      index(name(:fragments), [:package_id, :package_version_id],
        name: index_name(:fragments, "package")
      )
    )

    create_index_if_not_deferred(
      index(name(:fragments), [:file_id], name: index_name(:fragments, "file"))
    )

    create_index_if_not_deferred(
      index(name(:fragments), [:file_id, :line], name: index_name(:fragments, "file_line"))
    )

    create_index_if_not_deferred(
      index(name(:fragments), [:file_id, :kind, :line],
        name: index_name(:fragments, "file_kind_line")
      )
    )

    create_index_if_not_deferred(
      index(name(:fragments), [:kind, :name, :arity],
        name: index_name(:fragments, "kind_name_arity")
      )
    )

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

    create_index_if_not_deferred(
      index(name(:comments), [:file_id], name: index_name(:comments, "file"))
    )

    create_index_if_not_deferred(
      index(name(:comments), [:fragment_id], name: index_name(:comments, "fragment"))
    )

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

    create_index_if_not_deferred(
      index(name(:definitions), [:qualified_name], name: index_name(:definitions, "qualified"))
    )

    create_index_if_not_deferred(
      index(name(:definitions), [:fragment_id], name: index_name(:definitions, "fragment"))
    )

    create_index_if_not_deferred(
      index(name(:definitions), [:file_id, :line], name: index_name(:definitions, "file_line"))
    )

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

    create_index_if_not_deferred(
      index(name(:references), [:qualified_name], name: index_name(:references, "qualified"))
    )

    create_index_if_not_deferred(
      index(name(:references), [:fragment_id], name: index_name(:references, "fragment"))
    )

    create_index_if_not_deferred(
      index(name(:references), [:file_id, :line], name: index_name(:references, "file_line"))
    )

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

    create_index_if_not_deferred(
      index(name(:graph_nodes), [:qualified_name], name: index_name(:graph_nodes, "qualified"))
    )

    create_index_if_not_deferred(
      index(name(:graph_nodes), [:file_id], name: index_name(:graph_nodes, "file"))
    )

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

    create_index_if_not_deferred(
      index(name(:call_edges), [:caller_qualified_name], name: index_name(:call_edges, "caller"))
    )

    create_index_if_not_deferred(
      index(name(:call_edges), [:callee_qualified_name], name: index_name(:call_edges, "callee"))
    )

    create_index_if_not_deferred(
      index(name(:call_edges), [:file_id], name: index_name(:call_edges, "file"))
    )

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

    create_index_if_not_deferred(
      index(name(:tree_nodes), [:fragment_id], name: index_name(:tree_nodes, "fragment"))
    )

    backfill_duckdb_fragment_terms()
  end

  def down do
    Schema.tables()
    |> Enum.reverse()
    |> Enum.each(fn table -> drop_if_exists(table(name(table.name))) end)
  end

  defp create_index_if_not_deferred(index), do: create_if_not_exists(index)

  defp table_opts(opts \\ []), do: opts

  defp name(suffix), do: Schema.table_name(table_prefix(), suffix)
  defp index_name(table, suffix), do: Schema.index_name(table_prefix(), table, suffix)

  defp table_prefix do
    Application.fetch_env!(:exograph, __MODULE__)[:prefix]
  end

  defp backfill_duckdb_fragment_terms do
    execute(~s|DELETE FROM "#{name(:fragment_terms)}"|)

    execute(~s|
    INSERT INTO "#{name(:fragment_terms)}" (term_id, fragment_id)
    SELECT DISTINCT unnest(terms) AS term_id, id AS fragment_id
    FROM "#{name(:fragments)}"
    |)
  end
end
