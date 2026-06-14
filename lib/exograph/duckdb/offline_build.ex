defmodule Exograph.DuckDB.OfflineBuild do
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
  def file_stage_table(prefix), do: "#{prefix}_file_stage"

  def create_stages!(repo, prefix) do
    create_file_stage!(repo, prefix)
    create_stage!(repo, prefix)
    create_term_stage!(repo, prefix)
    create_definition_stage!(repo, prefix)
    create_reference_stage!(repo, prefix)
    create_comment_stage!(repo, prefix)
    create_fragment_term_stage!(repo, prefix)
    :ok
  end

  def create_file_stage!(repo, prefix) do
    repo.query!(
      QuackDB.DDL.create_table(file_stage_table(prefix), file_append_types(),
        if_not_exists: true
      ),
      [],
      timeout: :infinity
    )

    :ok
  end

  def append_file_stage!(repo, prefix, rows) when is_list(rows) do
    repo.insert_all(file_stage_table(prefix), rows,
      insert_method: :append,
      columns: file_append_types(),
      chunk_every: 10_000,
      timeout: :infinity
    )
  end

  def finalize_files!(repo, prefix) do
    stage_lock(repo, prefix, :files, fn ->
      repo.query!(finalize_files_sql(prefix), [], timeout: :infinity)

      %{rows: rows} = repo.query!(lookup_files_sql(prefix), [], timeout: :infinity)
      Map.new(rows, fn [package_version_id, sha256, id] -> {{package_version_id, sha256}, id} end)
    end)
  end

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
    %{
      files: finalize_files!(repo, prefix),
      terms: finalize_terms!(repo, prefix),
      fragments: finalize_fragments!(repo, prefix),
      definitions: finalize_definitions!(repo, prefix),
      references: finalize_references!(repo, prefix),
      comments: finalize_comments!(repo, prefix),
      fragment_terms: finalize_fragment_terms!(repo, prefix)
    }
  end

  def finalize_fragments!(repo, prefix) do
    repo.query!(finalize_sql(prefix), [], timeout: :infinity)

    %{rows: rows} = repo.query!(lookup_ids_sql(prefix), [], timeout: :infinity)
    Map.new(rows, fn [content_hash, id] -> {content_hash, id} end)
  end

  def definition_stage_table(prefix), do: fact_stage_table(prefix, :definition)
  def reference_stage_table(prefix), do: fact_stage_table(prefix, :reference)
  def comment_stage_table(prefix), do: fact_stage_table(prefix, :comment)
  def term_stage_table(prefix), do: "#{prefix}_term_stage"
  def fragment_term_stage_table(prefix), do: "#{prefix}_fragment_term_stage"

  def create_definition_stage!(repo, prefix), do: create_fact_stage!(repo, prefix, :definition)
  def create_reference_stage!(repo, prefix), do: create_fact_stage!(repo, prefix, :reference)
  def create_comment_stage!(repo, prefix), do: create_fact_stage!(repo, prefix, :comment)

  def create_term_stage!(repo, prefix) do
    repo.query!(
      QuackDB.DDL.create_table(term_stage_table(prefix), term_append_types(),
        if_not_exists: true
      ),
      [],
      timeout: :infinity
    )

    :ok
  end

  def create_fragment_term_stage!(repo, prefix) do
    repo.query!(
      QuackDB.DDL.create_table(fragment_term_stage_table(prefix), fragment_term_append_types(),
        if_not_exists: true
      ),
      [],
      timeout: :infinity
    )

    :ok
  end

  def append_definition_stage!(repo, prefix, rows),
    do: append_fact_stage!(repo, prefix, :definition, rows)

  def append_reference_stage!(repo, prefix, rows),
    do: append_fact_stage!(repo, prefix, :reference, rows)

  def append_comment_stage!(repo, prefix, rows),
    do: append_fact_stage!(repo, prefix, :comment, rows)

  def append_term_stage!(repo, prefix, rows) when is_list(rows) do
    repo.insert_all(term_stage_table(prefix), rows,
      insert_method: :append,
      columns: term_append_types(),
      chunk_every: 10_000,
      timeout: :infinity
    )
  end

  def append_fragment_term_stage!(repo, prefix, rows) when is_list(rows) do
    repo.insert_all(fragment_term_stage_table(prefix), rows,
      insert_method: :append,
      columns: fragment_term_append_types(),
      chunk_every: 10_000,
      timeout: :infinity
    )
  end

  def finalize_definitions!(repo, prefix), do: finalize_facts!(repo, prefix, :definition)
  def finalize_references!(repo, prefix), do: finalize_facts!(repo, prefix, :reference)
  def finalize_comments!(repo, prefix), do: finalize_facts!(repo, prefix, :comment)

  def finalize_terms!(repo, prefix) do
    stage_lock(repo, prefix, :terms, fn ->
      repo.query!(finalize_terms_sql(prefix), [], timeout: :infinity)

      %{rows: rows} = repo.query!(lookup_terms_sql(prefix), [], timeout: :infinity)
      Map.new(rows, fn [term, id] -> {term, id} end)
    end)
  end

  def finalize_fragment_terms!(repo, prefix) do
    repo.query!(finalize_fragment_terms_sql(prefix), [], timeout: :infinity)
  end

  defp finalize_files_sql(prefix) do
    target = quote_name("#{prefix}_files")
    stage = quote_name(file_stage_table(prefix))

    columns = file_columns() |> Enum.map_join(", ", &quote_name/1)
    select_columns = file_columns() |> Enum.map_join(", ", &["s.", quote_name(&1)])

    [
      "INSERT INTO ",
      target,
      " (",
      columns,
      ") SELECT ",
      select_columns,
      " FROM (SELECT *, row_number() OVER (PARTITION BY ",
      quote_name(:package_version_id),
      ", ",
      quote_name(:sha256),
      " ORDER BY ",
      quote_name(:path),
      ") AS exograph_stage_row FROM ",
      stage,
      ") AS s WHERE s.exograph_stage_row = 1 ON CONFLICT (",
      quote_name(:package_version_id),
      ", ",
      quote_name(:sha256),
      ") DO NOTHING"
    ]
  end

  defp lookup_files_sql(prefix) do
    target = quote_name("#{prefix}_files")
    stage = quote_name(file_stage_table(prefix))

    [
      "SELECT DISTINCT s.",
      quote_name(:package_version_id),
      ", s.",
      quote_name(:sha256),
      ", f.",
      quote_name(:id),
      " FROM ",
      stage,
      " AS s INNER JOIN ",
      target,
      " AS f ON f.",
      quote_name(:sha256),
      " = s.",
      quote_name(:sha256),
      " AND f.",
      quote_name(:package_version_id),
      " IS NOT DISTINCT FROM s.",
      quote_name(:package_version_id)
    ]
  end

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
      [],
      timeout: :infinity
    )

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

  defp finalize_terms_sql(prefix) do
    target = quote_name("#{prefix}_terms")
    stage = quote_name(term_stage_table(prefix))

    [
      "INSERT INTO ",
      target,
      " (",
      quote_name(:term),
      ") SELECT DISTINCT s.",
      quote_name(:term),
      " FROM ",
      stage,
      " AS s ON CONFLICT (",
      quote_name(:term),
      ") DO NOTHING"
    ]
  end

  defp lookup_terms_sql(prefix) do
    target = quote_name("#{prefix}_terms")
    stage = quote_name(term_stage_table(prefix))

    [
      "SELECT DISTINCT s.",
      quote_name(:term),
      ", t.",
      quote_name(:id),
      " FROM ",
      stage,
      " AS s INNER JOIN ",
      target,
      " AS t ON t.",
      quote_name(:term),
      " = s.",
      quote_name(:term)
    ]
  end

  defp finalize_fragment_terms_sql(prefix) do
    target = quote_name("#{prefix}_fragment_terms")
    stage = quote_name(fragment_term_stage_table(prefix))
    fragments = quote_name("#{prefix}_fragments")

    [
      "INSERT INTO ",
      target,
      " (",
      quote_name(:term_id),
      ", ",
      quote_name(:fragment_id),
      ") SELECT DISTINCT s.",
      quote_name(:term_id),
      ", f.",
      quote_name(:id),
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

  defp file_columns do
    [
      :package_id,
      :package_version_id,
      :path,
      :source,
      :comments_text,
      :sha256,
      :inserted_at,
      :updated_at
    ]
  end

  defp file_append_types do
    [
      package_id: :integer,
      package_version_id: :integer,
      path: :varchar,
      source: :varchar,
      comments_text: :varchar,
      sha256: :varchar,
      inserted_at: :timestamp,
      updated_at: :timestamp
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

  defp term_append_types do
    [term: :varchar]
  end

  defp fragment_term_append_types do
    [
      fragment_content_hash: :blob,
      term_id: :integer
    ]
  end

  defp stage_lock(repo, prefix, name, fun) do
    :global.trans({{__MODULE__, repo, prefix, name}, self()}, fun, [node()], 1_000_000)
  end

  defp quote_name(name), do: QuackDB.Type.quote_identifier(to_string(name))
end
