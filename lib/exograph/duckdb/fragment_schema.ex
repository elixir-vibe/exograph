defmodule Exograph.DuckDB.FragmentSchema do
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

  def columns, do: @columns
  def append_types, do: @append_types
  def ddl_types, do: @ddl_types
end
