defmodule Exograph.DuckDB.TextSearch do
  @moduledoc false

  alias Exograph.Hit
  alias Exograph.Storage.{FragmentRecord, Schema}

  def search_file_field(index, literal, field, opts) when field in [:source, :comments_text] do
    limit = Keyword.get(opts, :limit, 50)

    if index.bm25? do
      bm25_file_search(index, literal, field, limit, opts)
    else
      ilike_file_search(index, literal, field, limit, opts)
    end
  end

  defp bm25_file_search(index, literal, field, limit, opts) do
    {files_table, _schema} = Schema.files_source(index.prefix)
    schema = QuackDB.FTS.schema_name("main.#{files_table}")
    field_name = Atom.to_string(field)

    {scope_sql, scope_params} = package_version_scope(opts)

    statement = """
    WITH matched_files AS (
      SELECT
        id,
        source,
        path,
        "#{schema}".match_bm25(id, ?, fields := '#{field_name}') AS score
      FROM #{Exograph.Storage.SQL.table(index.prefix, "files")}
      WHERE "#{schema}".match_bm25(id, ?, fields := '#{field_name}') > 0#{scope_sql}
      ORDER BY score DESC, path ASC
      LIMIT ?
    )
    #{first_fragment_statement(index.prefix)}
    ORDER BY matched_files.score DESC, matched_files.path ASC, fr.line ASC
    """

    params = [literal, literal] ++ scope_params ++ [limit]
    {:ok, hits_from_rows(index.repo.query!(statement, params).rows)}
  rescue
    _ in [QuackDB.Error, Ecto.QueryError] ->
      ilike_file_search(index, literal, field, limit, opts)
  end

  defp ilike_file_search(index, literal, field, limit, opts) do
    column = Atom.to_string(field)
    pattern = "%#{escape_like(literal)}%"

    {scope_sql, scope_params} = package_version_scope(opts)

    statement = """
    WITH matched_files AS (
      SELECT id, source, path
      FROM #{Exograph.Storage.SQL.table(index.prefix, "files")}
      WHERE "#{column}" ILIKE ?#{scope_sql}
      ORDER BY path ASC
      LIMIT ?
    )
    #{first_fragment_statement(index.prefix)}
    ORDER BY matched_files.path ASC, fr.line ASC
    """

    params = [pattern] ++ scope_params ++ [limit]
    {:ok, hits_from_rows(index.repo.query!(statement, params).rows)}
  end

  defp package_version_scope(opts) do
    case Keyword.get(opts, :package_version_id) || Keyword.get(opts, :package_version) do
      id when is_integer(id) -> {" AND package_version_id = ?", [id]}
      _ -> {"", []}
    end
  end

  defp first_fragment_statement(prefix) do
    """
    SELECT
      fr.id, fr.package_id, fr.package_version_id, fr.file_id, fr.content_hash, fr.ast,
      fr.kind, fr.module, fr.name, fr.arity, fr.line, fr.end_line, fr.mass,
      fr.exact_hash, fr.terms, fr.sub_hashes, fr.inserted_at, fr.updated_at,
      matched_files.source, matched_files.path, pv.version
    FROM matched_files
    INNER JOIN LATERAL (
      SELECT
        id, package_id, package_version_id, file_id, content_hash, ast,
        kind, module, name, arity, line, end_line, mass,
        exact_hash, terms, sub_hashes, inserted_at, updated_at
      FROM #{Exograph.Storage.SQL.table(prefix, "fragments")}
      WHERE file_id = matched_files.id
      ORDER BY line ASC
      LIMIT 1
    ) AS fr ON true
    LEFT JOIN #{Exograph.Storage.SQL.table(prefix, "package_versions")} AS pv
      ON pv.id = fr.package_version_id
    """
  end

  defp hits_from_rows(rows) do
    Enum.map(rows, fn row ->
      {record, source, path, package_version} = fragment_record(row)

      Hit.new(
        fragment: Schema.hydrate_fragment(record, source, path, package_version),
        score: 1.0
      )
    end)
  end

  defp fragment_record([
         id,
         package_id,
         package_version_id,
         file_id,
         content_hash,
         ast,
         kind,
         module,
         name,
         arity,
         line,
         end_line,
         mass,
         exact_hash,
         terms,
         sub_hashes,
         inserted_at,
         updated_at,
         source,
         path,
         package_version
       ]) do
    {%FragmentRecord{
       id: id,
       package_id: package_id,
       package_version_id: package_version_id,
       file_id: file_id,
       content_hash: content_hash,
       ast: ast,
       kind: String.to_existing_atom(kind),
       module: module,
       name: name,
       arity: arity,
       line: line,
       end_line: end_line,
       mass: mass,
       exact_hash: exact_hash,
       terms: terms || [],
       sub_hashes: sub_hashes || [],
       inserted_at: inserted_at,
       updated_at: updated_at
     }, source, path, package_version}
  end

  defp escape_like(value), do: value |> String.replace("%", "\\%") |> String.replace("_", "\\_")
end
