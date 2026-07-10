defmodule Exograph.Storage.IndexFormat do
  @moduledoc false

  import Ecto.Query

  alias Exograph.Storage.{IndexFormatRecord, Schema}

  @format_version 3
  @parser_version 1

  def ensure_compatible!(repo, prefix) do
    source = Schema.source(:index_format, prefix)

    case repo.one(from(format in source, where: format.id == 1)) do
      %IndexFormatRecord{format_version: @format_version, parser_version: @parser_version} ->
        :ok

      %IndexFormatRecord{} = format ->
        raise ArgumentError,
              "unsupported Exograph index format #{format.format_version}/#{format.parser_version}; " <>
                "reindex with Exograph #{@format_version}/#{@parser_version}"

      nil ->
        raise ArgumentError,
              "index format metadata is missing; this index must be rebuilt with Exograph #{@format_version}"
    end
  end

  def write_current!(repo, prefix) do
    repo.insert_all(
      Schema.source(:index_format, prefix),
      [%{id: 1, format_version: @format_version, parser_version: @parser_version}],
      conflict_target: [:id],
      on_conflict: {:replace, [:format_version, :parser_version]}
    )

    :ok
  end
end
