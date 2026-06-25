defmodule Exograph.DuckDB.OfflineBuild do
  @moduledoc false

  import QuackDB.SQL.Fragment

  alias Exograph.DuckDB.FragmentSchema
  alias Exograph.Storage.Schema

  @columns FragmentSchema.columns()
  @append_types FragmentSchema.append_types()

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
    create_graph_node_stage!(repo, prefix)
    create_call_edge_stage!(repo, prefix)
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
      fragment_terms: finalize_fragment_terms!(repo, prefix),
      graph_nodes: finalize_graph_nodes!(repo, prefix),
      call_edges: finalize_call_edges!(repo, prefix)
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
  def graph_node_stage_table(prefix), do: "#{prefix}_graph_node_stage"
  def call_edge_stage_table(prefix), do: "#{prefix}_call_edge_stage"

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

  def create_graph_node_stage!(repo, prefix) do
    repo.query!(
      QuackDB.DDL.create_table(graph_node_stage_table(prefix), graph_node_append_types(),
        if_not_exists: true
      ),
      [],
      timeout: :infinity
    )

    :ok
  end

  def create_call_edge_stage!(repo, prefix) do
    repo.query!(
      QuackDB.DDL.create_table(call_edge_stage_table(prefix), call_edge_append_types(),
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

  def append_graph_node_stage!(repo, prefix, rows) when is_list(rows) do
    repo.insert_all(graph_node_stage_table(prefix), rows,
      insert_method: :append,
      columns: graph_node_append_types(),
      chunk_every: 10_000,
      timeout: :infinity
    )
  end

  def append_call_edge_stage!(repo, prefix, rows) when is_list(rows) do
    repo.insert_all(call_edge_stage_table(prefix), rows,
      insert_method: :append,
      columns: call_edge_append_types(),
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

  def finalize_graph_nodes!(repo, prefix) do
    repo.query!(finalize_graph_nodes_sql(prefix), [], timeout: :infinity)
  end

  def finalize_call_edges!(repo, prefix) do
    repo.query!(finalize_call_edges_sql(prefix), [], timeout: :infinity)
  end

  defp finalize_files_sql(prefix) do
    target = table_name(prefix, :files)
    stage = table(file_stage_table(prefix))

    [
      "INSERT INTO ",
      target,
      insert_columns(file_columns()),
      " SELECT ",
      qualified_column_list(file_columns(), :s),
      " FROM (SELECT *, ",
      row_number_over(
        partition_by: [:package_version_id, :sha256],
        order_by: [:path],
        as: :exograph_stage_row
      ),
      " FROM ",
      stage,
      ") AS ",
      alias_name(:s),
      " WHERE ",
      qualified_column(:s, :exograph_stage_row),
      " = 1",
      on_conflict({:nothing, [:package_version_id, :sha256]})
    ]
  end

  defp lookup_files_sql(prefix) do
    stage = table(file_stage_table(prefix))

    [
      "SELECT DISTINCT ",
      qualified_column(:s, :package_version_id),
      ", ",
      qualified_column(:s, :sha256),
      ", ",
      qualified_column(:f, :id),
      " FROM ",
      stage,
      " AS ",
      alias_name(:s),
      join(:inner, schema_table(prefix, :files),
        as: :f,
        on: [
          qualified_equality(:f, :sha256, :s, :sha256),
          " AND ",
          qualified_not_distinct(:f, :package_version_id, :s, :package_version_id)
        ]
      )
    ]
  end

  defp create_stage_sql(table) do
    QuackDB.DDL.create_table(table, @append_types, if_not_exists: true)
  end

  defp finalize_sql(prefix) do
    target = table_name(prefix, :fragments)
    stage = table(stage_table(prefix))

    [
      "INSERT INTO ",
      target,
      insert_columns(@columns),
      " SELECT ",
      qualified_column_list(@columns, :s),
      " FROM (SELECT *, ",
      row_number_over(
        partition_by: [:content_hash],
        order_by: [{:file_id, :asc, nulls: :last}, :line, {:end_line, :asc, nulls: :last}],
        as: :exograph_stage_row
      ),
      " FROM ",
      stage,
      where([column(:content_hash), " IS NOT NULL"]),
      ") AS ",
      alias_name(:s),
      " WHERE ",
      qualified_column(:s, :exograph_stage_row),
      " = 1",
      on_conflict({:nothing, [:content_hash]})
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
    columns = Enum.reject(fact_columns(kind), &(&1 == :fragment_content_hash))

    select_columns =
      Enum.reject(fact_columns(kind), &(&1 in [:fragment_content_hash, :fragment_id]))

    [
      "INSERT INTO ",
      table_name(prefix, fact_target_table(kind)),
      insert_columns(columns),
      " SELECT ",
      qualified_column_list(select_columns, :s),
      ", ",
      qualified_column(:f, :id),
      " AS ",
      column(:fragment_id),
      " FROM ",
      table(fact_stage_table(prefix, kind)),
      " AS ",
      alias_name(:s),
      join(:inner, schema_table(prefix, :fragments),
        as: :f,
        on: qualified_equality(:f, :content_hash, :s, :fragment_content_hash)
      )
    ]
  end

  defp finalize_terms_sql(prefix) do
    [
      "INSERT INTO ",
      table_name(prefix, :terms),
      insert_columns([:term]),
      " SELECT DISTINCT ",
      qualified_column(:s, :term),
      " FROM ",
      table(term_stage_table(prefix)),
      " AS ",
      alias_name(:s),
      on_conflict({:nothing, [:term]})
    ]
  end

  defp lookup_terms_sql(prefix) do
    [
      "SELECT DISTINCT ",
      qualified_column(:s, :term),
      ", ",
      qualified_column(:t, :id),
      " FROM ",
      table(term_stage_table(prefix)),
      " AS ",
      alias_name(:s),
      join(:inner, schema_table(prefix, :terms),
        as: :t,
        on: qualified_equality(:t, :term, :s, :term)
      )
    ]
  end

  defp finalize_fragment_terms_sql(prefix) do
    [
      "INSERT INTO ",
      table_name(prefix, :fragment_terms),
      insert_columns([:term_id, :fragment_id]),
      " SELECT DISTINCT ",
      qualified_column(:s, :term_id),
      ", ",
      qualified_column(:f, :id),
      " FROM ",
      table(fragment_term_stage_table(prefix)),
      " AS ",
      alias_name(:s),
      join(:inner, schema_table(prefix, :fragments),
        as: :f,
        on: qualified_equality(:f, :content_hash, :s, :fragment_content_hash)
      )
    ]
  end

  defp finalize_graph_nodes_sql(prefix) do
    select_columns =
      graph_node_columns()
      |> Enum.reject(&(&1 == :fragment_id))
      |> Enum.map_join(", ", &staged_select_column/1)

    [
      "INSERT INTO ",
      table_name(prefix, :graph_nodes),
      insert_columns(graph_node_columns()),
      " SELECT ",
      select_columns,
      ", ",
      qualified_column(:f, :id),
      " AS ",
      column(:fragment_id),
      " FROM ",
      table(graph_node_stage_table(prefix)),
      " AS ",
      alias_name(:s),
      join(:left, schema_table(prefix, :fragments),
        as: :f,
        on: qualified_equality(:f, :content_hash, :s, :fragment_content_hash)
      )
    ]
  end

  defp finalize_call_edges_sql(prefix) do
    target = table_name(prefix, :call_edges)
    stage = quote_name(call_edge_stage_table(prefix))
    node_stage = quote_name(graph_node_stage_table(prefix))
    graph_nodes = table_name(prefix, :graph_nodes)
    fragments = table_name(prefix, :fragments)

    columns = call_edge_columns() |> Enum.map_join(", ", &quote_name/1)

    [
      "INSERT INTO ",
      target,
      " (",
      columns,
      ") SELECT s.",
      quote_name(:package_id),
      ", s.",
      quote_name(:package_version_id),
      ", s.",
      quote_name(:file_id),
      ", caller_node.",
      quote_name(:id),
      ", callee_node.",
      quote_name(:id),
      ", call_fragment.",
      quote_name(:id),
      ", s.",
      quote_name(:caller_qualified_name),
      ", s.",
      quote_name(:callee_qualified_name),
      ", s.",
      quote_name(:line),
      ", s.",
      quote_name(:column),
      ", CAST(s.",
      quote_name(:metadata),
      " AS JSON), s.",
      quote_name(:inserted_at),
      ", s.",
      quote_name(:updated_at),
      " FROM ",
      stage,
      " AS s INNER JOIN ",
      node_stage,
      " AS caller_stage ON caller_stage.",
      quote_name(:original_node_id),
      " = s.",
      quote_name(:caller_original_node_id),
      " INNER JOIN ",
      node_stage,
      " AS callee_stage ON callee_stage.",
      quote_name(:original_node_id),
      " = s.",
      quote_name(:callee_original_node_id),
      " INNER JOIN ",
      graph_nodes,
      " AS caller_node ON ",
      graph_node_match_sql("caller_node", "caller_stage"),
      " INNER JOIN ",
      graph_nodes,
      " AS callee_node ON ",
      graph_node_match_sql("callee_node", "callee_stage"),
      " LEFT JOIN ",
      fragments,
      " AS call_fragment ON call_fragment.",
      quote_name(:content_hash),
      " = s.",
      quote_name(:call_site_fragment_content_hash)
    ]
  end

  defp lookup_ids_sql(prefix) do
    [
      "SELECT DISTINCT ",
      qualified_column(:s, :content_hash),
      ", ",
      qualified_column(:f, :id),
      " FROM ",
      table(stage_table(prefix)),
      " AS ",
      alias_name(:s),
      join(:inner, schema_table(prefix, :fragments),
        as: :f,
        on: qualified_equality(:f, :content_hash, :s, :content_hash)
      ),
      where([qualified_column(:s, :content_hash), " IS NOT NULL"])
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

  defp fact_target_table(:definition), do: :definitions
  defp fact_target_table(:reference), do: :references
  defp fact_target_table(:comment), do: :comments

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

  defp graph_node_columns do
    [
      :package_id,
      :package_version_id,
      :file_id,
      :engine,
      :external_id,
      :kind,
      :module,
      :name,
      :arity,
      :qualified_name,
      :line,
      :column,
      :metadata,
      :inserted_at,
      :updated_at,
      :fragment_id
    ]
  end

  defp graph_node_append_types do
    [
      original_node_id: :integer,
      package_id: :integer,
      package_version_id: :integer,
      file_id: :integer,
      engine: :varchar,
      external_id: :varchar,
      kind: :varchar,
      module: :varchar,
      name: :varchar,
      arity: :integer,
      qualified_name: :varchar,
      line: :integer,
      column: :integer,
      metadata: :varchar,
      inserted_at: :timestamp,
      updated_at: :timestamp,
      fragment_content_hash: :blob
    ]
  end

  defp call_edge_columns do
    [
      :package_id,
      :package_version_id,
      :file_id,
      :caller_node_id,
      :callee_node_id,
      :call_site_fragment_id,
      :caller_qualified_name,
      :callee_qualified_name,
      :line,
      :column,
      :metadata,
      :inserted_at,
      :updated_at
    ]
  end

  defp call_edge_append_types do
    [
      package_id: :integer,
      package_version_id: :integer,
      file_id: :integer,
      caller_original_node_id: :integer,
      callee_original_node_id: :integer,
      call_site_fragment_content_hash: :blob,
      caller_qualified_name: :varchar,
      callee_qualified_name: :varchar,
      line: :integer,
      column: :integer,
      metadata: :varchar,
      inserted_at: :timestamp,
      updated_at: :timestamp
    ]
  end

  defp staged_select_column(:metadata), do: ["CAST(s.", quote_name(:metadata), " AS JSON)"]
  defp staged_select_column(column), do: ["s.", quote_name(column)]

  defp graph_node_match_sql(node_alias, stage_alias) do
    [
      node_alias,
      ".",
      quote_name(:package_version_id),
      " IS NOT DISTINCT FROM ",
      stage_alias,
      ".",
      quote_name(:package_version_id),
      " AND ",
      node_alias,
      ".",
      quote_name(:file_id),
      " IS NOT DISTINCT FROM ",
      stage_alias,
      ".",
      quote_name(:file_id),
      " AND ",
      node_alias,
      ".",
      quote_name(:engine),
      " = ",
      stage_alias,
      ".",
      quote_name(:engine),
      " AND ",
      node_alias,
      ".",
      quote_name(:kind),
      " = ",
      stage_alias,
      ".",
      quote_name(:kind),
      " AND ",
      node_alias,
      ".",
      quote_name(:qualified_name),
      " = ",
      stage_alias,
      ".",
      quote_name(:qualified_name),
      " AND ",
      node_alias,
      ".",
      quote_name(:external_id),
      " IS NOT DISTINCT FROM ",
      stage_alias,
      ".",
      quote_name(:external_id)
    ]
  end

  defp stage_lock(repo, prefix, name, fun) do
    :global.trans({{__MODULE__, repo, prefix, name}, self()}, fun, [node()], 1_000_000)
  end

  defp schema_table(prefix, name), do: Schema.table_name(prefix, name)
  defp table_name(prefix, name), do: table(schema_table(prefix, name))

  defp quote_name(name), do: QuackDB.Type.quote_identifier(to_string(name))
end
