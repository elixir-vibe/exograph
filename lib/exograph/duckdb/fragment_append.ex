defmodule Exograph.DuckDB.FragmentAppend do
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

  def insert_by_hash(_repo, _source, _schema, []), do: %{}

  def insert_by_hash(repo, source, schema, entries) do
    target = {source, schema}

    rows =
      entries
      |> Enum.reject(&is_nil(&1.content_hash))
      |> Enum.uniq_by(& &1.content_hash)

    if rows == [] do
      %{}
    else
      Exograph.Hex.StageTimings.measure(:fragment_append_rows, fn ->
        if merge_append?() do
          merge_insert_by_hash(repo, source, rows)
        else
          ecto_insert_by_hash(repo, target, rows)
        end
      end)
    end
  end

  defp merge_append?, do: System.get_env("EXOGRAPH_DUCKDB_FRAGMENT_APPEND") == "merge"

  defp ecto_insert_by_hash(repo, target, rows) do
    {_count, returning} =
      repo.insert_all(target, rows,
        insert_method: :append,
        chunk_every: 2_000,
        conflict_target: [:content_hash],
        on_conflict: :nothing,
        returning: [:id, :content_hash],
        timeout: :infinity
      )

    Map.new(returning, fn row -> {row.content_hash, row.id} end)
  end

  defp merge_insert_by_hash(repo, source, rows) do
    temp_table = temp_table_name(source)

    {:ok, inserted_by_hash} =
      repo.transaction(
        fn ->
          repo.query!(create_temp_table_sql(temp_table), [], timeout: :infinity)
          repo.query!(clear_temp_table_sql(temp_table), [], timeout: :infinity)

          repo.insert_all(temp_table, rows,
            insert_method: :append,
            chunk_every: 2_000,
            columns: @append_types,
            timeout: :infinity
          )

          %{rows: returning} = repo.query!(merge_sql(source, temp_table), [], timeout: :infinity)
          repo.query!(clear_temp_table_sql(temp_table), [], timeout: :infinity)
          Map.new(returning, fn [content_hash, id] -> {content_hash, id} end)
        end,
        timeout: :infinity
      )

    inserted_by_hash
  end

  defp temp_table_name(source) do
    hash = :erlang.phash2(source, 4_294_967_296) |> Integer.to_string(36)
    "exograph_fragment_merge_#{hash}"
  end

  defp create_temp_table_sql(table) do
    columns =
      Enum.map_join(@ddl_types, ", ", fn {name, type} ->
        [quote_name(name), " ", type]
      end)

    ["CREATE TEMP TABLE IF NOT EXISTS ", quote_name(table), " (", columns, ")"]
  end

  defp clear_temp_table_sql(table), do: ["DELETE FROM ", quote_name(table)]

  defp merge_sql(source, temp_table) do
    target = quote_name(source)
    stage = quote_name(temp_table)
    columns = Enum.map_join(@columns, ", ", &quote_name/1)
    values = Enum.map_join(@columns, ", ", &["s.", quote_name(&1)])

    [
      "MERGE INTO ",
      target,
      " AS t USING ",
      stage,
      " AS s ON t.",
      quote_name(:content_hash),
      " = s.",
      quote_name(:content_hash),
      " WHEN NOT MATCHED THEN INSERT (",
      columns,
      ") VALUES (",
      values,
      ") RETURNING ",
      quote_name(:content_hash),
      ", ",
      quote_name(:id)
    ]
  end

  defp quote_name(name), do: QuackDB.Type.quote_identifier(to_string(name))
end
