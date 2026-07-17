defmodule Exograph.DuckDB.Compactor do
  @moduledoc false

  @lock_retry_timeout_ms 30_000
  @lock_retry_interval_ms 100

  def compact_manifest!(manifest) do
    manifest
    |> Exograph.DuckDBShards.load_manifest()
    |> Map.fetch!(:shards)
    |> Enum.each(&compact!(&1.database))

    :ok
  end

  def compact!(database) when is_binary(database) do
    database = Path.expand(database)
    temporary = "#{database}.compact-#{System.unique_integer([:positive])}"
    backup = "#{database}.uncompacted-#{System.unique_integer([:positive])}"

    File.rm(temporary)

    try do
      run_copy!(database, temporary)
      replace_database!(database, temporary, backup)
      File.rm("#{database}.wal")
      :ok
    after
      File.rm(temporary)
    end
  end

  defp replace_database!(database, temporary, backup) do
    File.rename!(database, backup)

    case File.rename(temporary, database) do
      :ok ->
        File.rm!(backup)

      {:error, reason} ->
        File.rename!(backup, database)
        raise File.Error, reason: reason, action: "replace", path: database
    end
  end

  defp run_copy!(source, destination) do
    statement =
      IO.iodata_to_binary([
        "ATTACH ",
        QuackDB.SQL.literal!(source),
        " AS exograph_source (READ_ONLY); ",
        "ATTACH ",
        QuackDB.SQL.literal!(destination),
        " AS exograph_compact; ",
        "COPY FROM DATABASE exograph_source TO exograph_compact;"
      ])

    deadline = System.monotonic_time(:millisecond) + @lock_retry_timeout_ms
    run_copy_with_lock_retry!(statement, deadline)
  end

  defp run_copy_with_lock_retry!(statement, deadline) do
    case System.cmd(QuackDB.Binary.path!(), [":memory:", "-c", statement], stderr_to_stdout: true) do
      {_output, 0} ->
        :ok

      {output, status} ->
        if lock_conflict?(output) and System.monotonic_time(:millisecond) < deadline do
          Process.sleep(@lock_retry_interval_ms)
          run_copy_with_lock_retry!(statement, deadline)
        else
          raise "DuckDB compaction failed with status #{status}: #{output}"
        end
    end
  end

  defp lock_conflict?(output) do
    String.contains?(output, "Could not set lock on file") or
      String.contains?(output, "Conflicting lock is held")
  end
end
