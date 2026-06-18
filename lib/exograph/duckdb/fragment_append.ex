defmodule Exograph.DuckDB.FragmentAppend do
  @moduledoc false

  alias Exograph.DuckDB.FragmentSchema

  @columns FragmentSchema.columns()
  @append_types FragmentSchema.append_types()
  @ddl_types FragmentSchema.ddl_types()

  def insert_by_hash(repo, source, schema, entries, opts \\ [])

  def insert_by_hash(_repo, _source, _schema, [], _opts), do: %{}

  def insert_by_hash(repo, source, schema, entries, opts) do
    target = {source, schema}

    rows =
      entries
      |> Enum.reject(&is_nil(&1.content_hash))
      |> Enum.uniq_by(& &1.content_hash)

    if rows == [] do
      %{}
    else
      Exograph.Hex.StageTimings.count(:fragment_append_input_rows, length(rows))
      insert_rows_by_hash(repo, source, target, rows, opts, Keyword.get(opts, :retries, 3))
    end
  end

  defp insert_rows_by_hash(repo, source, target, rows, opts, retries_left) do
    Exograph.Hex.StageTimings.count(:fragment_append_attempts)
    Exograph.Hex.StageTimings.count(:fragment_append_attempt_rows, length(rows))

    Exograph.Hex.StageTimings.measure(:fragment_append_rows, fn ->
      if merge_append?(opts) do
        merge_insert_by_hash(repo, source, rows, opts)
      else
        ecto_insert_by_hash(repo, target, rows)
      end
    end)
  rescue
    error ->
      if retries_left > 0 and unique_constraint_race?(error) do
        Exograph.Hex.StageTimings.count(:fragment_append_retries)
        Process.sleep(retry_backoff_ms(retries_left))
        insert_rows_by_hash(repo, source, target, rows, opts, retries_left - 1)
      else
        reraise error, __STACKTRACE__
      end
  end

  defp merge_append?(opts), do: Keyword.get(opts, :mode, :ecto) == :merge

  defp unique_constraint_race?(error) do
    message = Exception.message(error)

    String.contains?(message, "PRIMARY KEY or UNIQUE constraint violation") or
      String.contains?(message, "violates unique constraint")
  end

  defp retry_backoff_ms(retries_left), do: max(1, 4 - retries_left) * 25

  defp ecto_insert_by_hash(repo, target, rows) do
    {_count, returning} =
      Exograph.Hex.StageTimings.measure(:fragment_append_ecto_insert, fn ->
        repo.insert_all(target, rows,
          insert_method: :append,
          chunk_every: 2_000,
          conflict_target: [:content_hash],
          on_conflict: :nothing,
          returning: [:id, :content_hash],
          timeout: :infinity
        )
      end)

    Exograph.Hex.StageTimings.count(:fragment_append_returned_rows, length(returning))
    Map.new(returning, fn row -> {row.content_hash, row.id} end)
  end

  defp merge_insert_by_hash(repo, source, rows, opts) do
    temp_table = temp_table_name(source)

    {:ok, inserted_by_hash} =
      Exograph.Hex.StageTimings.measure(:fragment_append_transaction, fn ->
        repo.transaction(
          fn ->
            Exograph.Hex.StageTimings.measure(:fragment_append_create_stage, fn ->
              repo.query!(create_temp_table_sql(temp_table), [], timeout: :infinity)
            end)

            Exograph.Hex.StageTimings.measure(:fragment_append_clear_stage_before, fn ->
              repo.query!(clear_temp_table_sql(temp_table), [], timeout: :infinity)
            end)

            if Keyword.get(opts, :payload_metrics?, false) do
              Exograph.Hex.StageTimings.measure(:fragment_append_payload_attribution, fn ->
                record_payload_attribution(rows)
              end)
            end

            Exograph.Hex.StageTimings.measure(:fragment_append_stage_rows, fn ->
              repo.insert_all(temp_table, rows,
                insert_method: :append,
                chunk_every: 10_000,
                columns: @append_types,
                timeout: :infinity
              )
            end)

            %{rows: returning} =
              Exograph.Hex.StageTimings.measure(:fragment_append_merge_query, fn ->
                repo.query!(merge_sql(source, temp_table), [], timeout: :infinity)
              end)

            Exograph.Hex.StageTimings.count(:fragment_append_returned_rows, length(returning))

            Exograph.Hex.StageTimings.measure(:fragment_append_clear_stage_after, fn ->
              repo.query!(clear_temp_table_sql(temp_table), [], timeout: :infinity)
            end)

            Map.new(returning, fn [content_hash, id] -> {content_hash, id} end)
          end,
          timeout: :infinity
        )
      end)

    inserted_by_hash
  end

  defp record_payload_attribution(rows) do
    Enum.each(@append_types, fn {column, type} ->
      {bytes, nulls, elements, max_bytes} =
        Enum.reduce(rows, {0, 0, 0, 0}, fn row, {bytes, nulls, elements, max_bytes} ->
          value = Map.get(row, column)
          value_bytes = approximate_payload_bytes(value, type)

          {
            bytes + value_bytes,
            nulls + if(is_nil(value), do: 1, else: 0),
            elements + payload_elements(value, type),
            max(max_bytes, value_bytes)
          }
        end)

      count(payload_metric(:bytes, column), bytes)
      count(payload_metric(:nulls, column), nulls)
      count(payload_metric(:elements, column), elements)
      count(payload_metric(:max_bytes, column), max_bytes)
    end)
  end

  defp approximate_payload_bytes(nil, _type), do: 0
  defp approximate_payload_bytes(value, :blob) when is_binary(value), do: byte_size(value)
  defp approximate_payload_bytes(value, :varchar) when is_binary(value), do: byte_size(value)
  defp approximate_payload_bytes(_value, :integer), do: 8
  defp approximate_payload_bytes(_value, :timestamp), do: 8

  defp approximate_payload_bytes(values, {:list, :integer}) when is_list(values) do
    length(values) * 8
  end

  defp approximate_payload_bytes(_value, _type), do: 0

  defp payload_elements(values, {:list, :integer}) when is_list(values), do: length(values)
  defp payload_elements(_value, _type), do: 1

  defp payload_metric(kind, column),
    do: String.to_atom("fragment_append_payload_#{kind}_#{column}")

  defp count(_metric, 0), do: :ok
  defp count(metric, amount), do: Exograph.Hex.StageTimings.count(metric, amount)

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
    QuackDB.DML.merge_into(source,
      using: temp_table,
      target_as: :target,
      source_as: :source,
      on: [:content_hash],
      when_not_matched: {:insert, @columns},
      returning: [:content_hash, :id]
    )
  end

  defp quote_name(name), do: QuackDB.Type.quote_identifier(to_string(name))
end
