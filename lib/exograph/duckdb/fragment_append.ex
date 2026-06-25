defmodule Exograph.DuckDB.FragmentAppend do
  @moduledoc false

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
      ecto_insert_by_hash(repo, target, rows)
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
end
