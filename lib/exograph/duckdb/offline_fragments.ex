defmodule Exograph.DuckDB.OfflineFragments do
  @moduledoc false

  @columns [
    :package_id,
    :package_version_id,
    :file_id,
    :content_hash,
    :ast,
    :kind,
    :module,
    :name,
    :arity,
    :line,
    :end_line,
    :mass,
    :exact_hash,
    :terms,
    :sub_hashes,
    :inserted_at,
    :updated_at
  ]

  @append_types [
    package_id: :integer,
    package_version_id: :integer,
    file_id: :integer,
    content_hash: :blob,
    ast: :blob,
    kind: :varchar,
    module: :varchar,
    name: :varchar,
    arity: :integer,
    line: :integer,
    end_line: :integer,
    mass: :integer,
    exact_hash: :blob,
    terms: {:list, :integer},
    sub_hashes: {:list, :integer},
    inserted_at: :timestamp,
    updated_at: :timestamp
  ]

  @ddl_types [
    package_id: "BIGINT",
    package_version_id: "BIGINT",
    file_id: "BIGINT",
    content_hash: "BLOB",
    ast: "BLOB",
    kind: "VARCHAR",
    module: "VARCHAR",
    name: "VARCHAR",
    arity: "BIGINT",
    line: "BIGINT",
    end_line: "BIGINT",
    mass: "BIGINT",
    exact_hash: "BLOB",
    terms: "BIGINT[]",
    sub_hashes: "BIGINT[]",
    inserted_at: "TIMESTAMP",
    updated_at: "TIMESTAMP"
  ]

  def stage_table(prefix), do: "#{prefix}_fragment_stage"

  def create_stage!(repo, prefix) do
    repo.query!(create_stage_sql(stage_table(prefix)), [], timeout: :infinity)
    :ok
  end

  def clear_stage!(repo, prefix) do
    repo.query!(["DELETE FROM ", quote_name(stage_table(prefix))], [], timeout: :infinity)
    :ok
  end

  def append_stage!(repo, prefix, rows) when is_list(rows) do
    repo.insert_all(stage_table(prefix), rows,
      insert_method: :append,
      columns: @append_types,
      chunk_every: 10_000,
      timeout: :infinity
    )
  end

  def finalize!(repo, prefix) do
    repo.query!(finalize_sql(prefix), [], timeout: :infinity)

    %{rows: rows} = repo.query!(lookup_ids_sql(prefix), [], timeout: :infinity)
    Map.new(rows, fn [content_hash, id] -> {content_hash, id} end)
  end

  defp create_stage_sql(table) do
    columns =
      Enum.map_join(@ddl_types, ", ", fn {name, type} ->
        [quote_name(name), " ", type]
      end)

    ["CREATE TABLE IF NOT EXISTS ", quote_name(table), " (", columns, ")"]
  end

  defp finalize_sql(prefix) do
    target = quote_name("#{prefix}_fragments")
    stage = quote_name(stage_table(prefix))
    columns = Enum.map_join(@columns, ", ", &quote_name/1)
    select_columns = Enum.map_join(@columns, ", ", &["s.", quote_name(&1)])

    [
      "INSERT INTO ",
      target,
      " (",
      columns,
      ") SELECT ",
      select_columns,
      " FROM (SELECT *, row_number() OVER (PARTITION BY ",
      quote_name(:content_hash),
      " ORDER BY ",
      quote_name(:file_id),
      " NULLS LAST, ",
      quote_name(:line),
      ", ",
      quote_name(:end_line),
      " NULLS LAST) AS exograph_stage_row FROM ",
      stage,
      " WHERE ",
      quote_name(:content_hash),
      " IS NOT NULL) AS s WHERE s.exograph_stage_row = 1 ON CONFLICT (",
      quote_name(:content_hash),
      ") DO NOTHING"
    ]
  end

  defp lookup_ids_sql(prefix) do
    target = quote_name("#{prefix}_fragments")
    stage = quote_name(stage_table(prefix))

    [
      "SELECT DISTINCT s.",
      quote_name(:content_hash),
      ", f.",
      quote_name(:id),
      " FROM ",
      stage,
      " AS s INNER JOIN ",
      target,
      " AS f ON f.",
      quote_name(:content_hash),
      " = s.",
      quote_name(:content_hash),
      " WHERE s.",
      quote_name(:content_hash),
      " IS NOT NULL"
    ]
  end

  defp quote_name(name), do: QuackDB.Type.quote_identifier(to_string(name))
end
