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

  def definition_stage_table(prefix), do: fact_stage_table(prefix, :definition)
  def reference_stage_table(prefix), do: fact_stage_table(prefix, :reference)
  def comment_stage_table(prefix), do: fact_stage_table(prefix, :comment)

  def create_definition_stage!(repo, prefix), do: create_fact_stage!(repo, prefix, :definition)
  def create_reference_stage!(repo, prefix), do: create_fact_stage!(repo, prefix, :reference)
  def create_comment_stage!(repo, prefix), do: create_fact_stage!(repo, prefix, :comment)

  def append_definition_stage!(repo, prefix, rows),
    do: append_fact_stage!(repo, prefix, :definition, rows)

  def append_reference_stage!(repo, prefix, rows),
    do: append_fact_stage!(repo, prefix, :reference, rows)

  def append_comment_stage!(repo, prefix, rows),
    do: append_fact_stage!(repo, prefix, :comment, rows)

  def finalize_definitions!(repo, prefix), do: finalize_facts!(repo, prefix, :definition)
  def finalize_references!(repo, prefix), do: finalize_facts!(repo, prefix, :reference)
  def finalize_comments!(repo, prefix), do: finalize_facts!(repo, prefix, :comment)

  defp create_stage_sql(table) do
    QuackDB.DDL.create_table(table, @append_types, if_not_exists: true)
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

  defp create_fact_stage!(repo, prefix, kind) do
    repo.query!(
      QuackDB.DDL.create_table(fact_stage_table(prefix, kind), fact_append_types(kind),
        if_not_exists: true
      ),
      [], timeout: :infinity)

    :ok
  end

  defp append_fact_stage!(repo, prefix, kind, rows) when is_list(rows) do
    repo.insert_all(fact_stage_table(prefix, kind), rows,
      insert_method: :append,
      columns: fact_append_types(kind),
      chunk_every: 10_000,
      timeout: :infinity
    )
  end

  defp finalize_facts!(repo, prefix, kind) do
    repo.query!(finalize_facts_sql(prefix, kind), [], timeout: :infinity)
  end

  defp finalize_facts_sql(prefix, kind) do
    target = quote_name("#{prefix}_#{fact_target_suffix(kind)}")
    stage = quote_name(fact_stage_table(prefix, kind))
    fragments = quote_name("#{prefix}_fragments")

    columns =
      fact_columns(kind)
      |> Enum.reject(&(&1 == :fragment_content_hash))
      |> Enum.map_join(", ", &quote_name/1)

    select_columns =
      fact_columns(kind)
      |> Enum.reject(&(&1 in [:fragment_content_hash, :fragment_id]))
      |> Enum.map_join(", ", &["s.", quote_name(&1)])

    [
      "INSERT INTO ",
      target,
      " (",
      columns,
      ") SELECT ",
      select_columns,
      ", f.",
      quote_name(:id),
      " AS ",
      quote_name(:fragment_id),
      " FROM ",
      stage,
      " AS s INNER JOIN ",
      fragments,
      " AS f ON f.",
      quote_name(:content_hash),
      " = s.",
      quote_name(:fragment_content_hash)
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

  defp fact_stage_table(prefix, :definition), do: "#{prefix}_definition_stage"
  defp fact_stage_table(prefix, :reference), do: "#{prefix}_reference_stage"
  defp fact_stage_table(prefix, :comment), do: "#{prefix}_comment_stage"

  defp fact_target_suffix(:definition), do: "definitions"
  defp fact_target_suffix(:reference), do: "references"
  defp fact_target_suffix(:comment), do: "comments"

  defp fact_columns(kind) when kind in [:definition, :reference] do
    [
      :package_id,
      :package_version_id,
      :file_id,
      :kind,
      :module,
      :name,
      :arity,
      :qualified_name,
      :line,
      :column,
      :inserted_at,
      :updated_at,
      :fragment_content_hash,
      :fragment_id
    ]
  end

  defp fact_columns(:comment) do
    [
      :package_id,
      :package_version_id,
      :file_id,
      :text,
      :line,
      :column,
      :inserted_at,
      :updated_at,
      :fragment_content_hash,
      :fragment_id
    ]
  end

  defp fact_append_types(kind) when kind in [:definition, :reference] do
    [
      package_id: :integer,
      package_version_id: :integer,
      file_id: :integer,
      kind: :varchar,
      module: :varchar,
      name: :varchar,
      arity: :integer,
      qualified_name: :varchar,
      line: :integer,
      column: :integer,
      inserted_at: :timestamp,
      updated_at: :timestamp,
      fragment_content_hash: :blob
    ]
  end

  defp fact_append_types(:comment) do
    [
      package_id: :integer,
      package_version_id: :integer,
      file_id: :integer,
      text: :varchar,
      line: :integer,
      column: :integer,
      inserted_at: :timestamp,
      updated_at: :timestamp,
      fragment_content_hash: :blob
    ]
  end

  defp quote_name(name), do: QuackDB.Type.quote_identifier(to_string(name))
end
