defmodule Exograph.Storage.Ecto.FragmentStore do
  @moduledoc """
  Durable fragment store backed by Ecto repositories.
  """

  import Ecto.Query

  alias Exograph.{
    Comment,
    Definition,
    File,
    FragmentLocator,
    Package,
    PackageVersion,
    Reference
  }

  alias Exograph.Extractor.Reach, as: ReachExtractor

  alias Exograph.Storage.Ecto.{
    CallEdgeRecord,
    CommentRecord,
    DefinitionRecord,
    FileRecord,
    FragmentRecord,
    GraphNodeRecord,
    Options,
    PackageRecord,
    PackageVersionRecord,
    ReferenceRecord,
    SQL
  }

  @noise_references MapSet.new(
                      ~w(|/2 ::/2 =/2 %{}/0 %{}/1 {}/2 {}/3 ->/2 |>/2 %/2 @/1 fn/1 \\/2
                         __block__/1 __block__/2 __block__/3 __block__/4 __block__/5 __block__/6 __block__/7 __block__/8 __block__/9 __block__/10
                         __exograph_unknown_atom__ __exograph_unknown_atom__/0 __exograph_unknown_atom__/1 __exograph_unknown_atom__/2 __exograph_unknown_atom__/3
                         @doc @moduledoc @typedoc @spec @type @typep @callback @macrocallback
                         doc/1 moduledoc/1 typedoc/1 spec/1 type/1 typep/1 callback/1 macrocallback/1
                         any/0 atom/0 binary/0 boolean/0 float/0 function/0 integer/0 list/0 map/0 none/0 non_neg_integer/0 number/0 pid/0 port/0 reference/0 term/0 timeout/0)
                    )

  defstruct repo: nil,
            prefix: "exograph",
            package: nil,
            package_version: nil,
            extractors: [:ex_ast, :reach],
            postgres_copy?: false,
            defer_fragment_terms?: false,
            duckdb_insert_buffer: nil

  @type t :: %__MODULE__{
          repo: module(),
          prefix: String.t(),
          package: Package.t() | nil,
          package_version: PackageVersion.t() | nil,
          extractors: keyword() | [atom()],
          postgres_copy?: boolean(),
          defer_fragment_terms?: boolean(),
          duckdb_insert_buffer: pid() | nil
        }

  def new(opts \\ []), do: {:ok, Options.store(__MODULE__, opts)}

  def put(%__MODULE__{} = store, fragments) when is_list(fragments) do
    now = DateTime.utc_now(:microsecond)

    store =
      Exograph.Hex.StageTimings.measure(:fragment_store_package_context, fn ->
        ensure_package_context(store, now)
      end)

    files =
      Exograph.Hex.StageTimings.measure(:fragment_store_upsert_files, fn ->
        upsert_files(store, fragments, now)
      end)

    files_by_path = Map.new(files, &{&1.path, &1})

    package_id = store.package && store.package.id
    package_version_id = store.package_version && store.package_version.id

    resolved_fragments =
      Enum.map(fragments, fn fragment ->
        file = files_by_path[fragment.file]
        file_id = if file, do: file.id, else: fragment.file_id

        %{
          fragment
          | file_id: file_id,
            package_id: package_id || fragment.package_id,
            package_version_id: package_version_id || fragment.package_version_id
        }
      end)

    resolved_fragments =
      Exograph.Hex.StageTimings.measure(:fragment_store_upsert_fragments, fn ->
        upsert_fragments(store, resolved_fragments, now)
      end)

    Exograph.Hex.StageTimings.measure(:fragment_store_code_facts, fn ->
      upsert_code_facts(store, files, resolved_fragments, now)
    end)

    {:ok, store}
  end

  def get(%__MODULE__{} = store, fragment_id) do
    query =
      from(fragment in {source(store), FragmentRecord},
        left_join: file in ^files_source(store),
        on: file.id == fragment.file_id,
        where: fragment.id == ^fragment_id,
        select: {fragment, file.source, file.path}
      )

    case store.repo.one(query) do
      {%FragmentRecord{} = record, source, path} ->
        {:ok, Options.hydrate_fragment(record, source, path)}

      nil ->
        :error
    end
  end

  def all(%__MODULE__{} = store) do
    query =
      from(fragment in {source(store), FragmentRecord},
        left_join: file in ^files_source(store),
        on: file.id == fragment.file_id,
        order_by: [asc: file.path, asc: fragment.line, asc: fragment.id],
        select: {fragment, file.source, file.path}
      )

    store.repo.all(query)
    |> Enum.map(fn {record, source, path} -> Options.hydrate_fragment(record, source, path) end)
  end

  def count(%__MODULE__{} = store) do
    store.repo.aggregate({source(store), FragmentRecord}, :count)
  end

  def page(%__MODULE__{} = store, offset, limit, opts \\ []) do
    import Ecto.Query

    query =
      from(fragment in {source(store), FragmentRecord},
        left_join: file in ^files_source(store),
        on: file.id == fragment.file_id,
        order_by: [asc: file.path, asc: fragment.line, asc: fragment.id],
        offset: ^offset,
        limit: ^limit,
        select: {fragment, file.source, file.path}
      )

    query =
      case Keyword.get(opts, :package_id) do
        nil -> query
        pid -> where(query, [fragment], fragment.package_id == ^pid)
      end

    query =
      case Keyword.get(opts, :package_version_id) || Keyword.get(opts, :package_version) do
        nil -> query
        pvid -> where(query, [fragment], fragment.package_version_id == ^pvid)
      end

    store.repo.all(query)
    |> Enum.map(fn {record, source, path} -> Options.hydrate_fragment(record, source, path) end)
  end

  def term_frequencies(_store, []), do: %{}

  def term_frequencies(%__MODULE__{} = store, terms) when is_list(terms) do
    term_to_id = load_term_ids(store, terms)

    if map_size(term_to_id) == 0 do
      %{}
    else
      ids = Map.values(term_to_id)
      id_to_term = Map.new(term_to_id, fn {term, id} -> {id, term} end)

      # unnest + GROUP BY has no Ecto DSL equivalent
      {:ok, %{rows: rows}} =
        SQL.query(
          store.repo,
          """
          SELECT term_id, count(*)::bigint
          FROM #{source(store)}, unnest(terms) AS term_id
          WHERE term_id = ANY($1)
          GROUP BY term_id
          """,
          [ids]
        )

      Map.new(rows, fn [id, count] -> {Map.fetch!(id_to_term, id), count} end)
    end
  end

  defp ensure_package_context(%__MODULE__{package: nil, package_version: nil} = store, _now),
    do: store

  defp ensure_package_context(%__MODULE__{} = store, now) do
    package = store.package || package_from_version(store.package_version)

    {_count, pkg_returning} =
      store.repo.insert_all(
        {"#{store.prefix}_packages", PackageRecord},
        [PackageRecord.from_package(package) |> Map.merge(%{inserted_at: now, updated_at: now})],
        conflict_target: [:ecosystem, :name],
        on_conflict: :nothing,
        returning: [:id],
        timeout: :infinity
      )

    package_id =
      case pkg_returning do
        [%{id: id}] ->
          id

        [] ->
          from(p in {"#{store.prefix}_packages", PackageRecord},
            where: p.ecosystem == ^to_string(package.ecosystem) and p.name == ^package.name,
            select: p.id
          )
          |> store.repo.one!()
      end

    package = %{package | id: package_id}
    store = %{store | package: package}

    if store.package_version do
      pv = %{store.package_version | package_id: package_id}

      {_count, pv_returning} =
        store.repo.insert_all(
          {"#{store.prefix}_package_versions", PackageVersionRecord},
          [
            PackageVersionRecord.from_package_version(pv)
            |> Map.merge(%{inserted_at: now, updated_at: now})
          ],
          conflict_target: [:package_id, :version],
          on_conflict: :nothing,
          returning: [:id],
          timeout: :infinity
        )

      pv_version = pv.version

      package_version_id =
        case pv_returning do
          [%{id: id}] ->
            id

          [] ->
            from(pv_row in {"#{store.prefix}_package_versions", PackageVersionRecord},
              where: pv_row.package_id == ^package_id and pv_row.version == ^pv_version,
              select: pv_row.id
            )
            |> store.repo.one!()
        end

      %{store | package_version: %{pv | id: package_version_id}}
    else
      store
    end
  end

  defp upsert_files(_store, [], _now), do: []

  defp upsert_files(store, fragments, now) do
    package_id = store.package && store.package.id
    package_version_id = store.package_version && store.package_version.id

    raw_files =
      fragments
      |> Enum.reject(&is_nil(&1.file))
      |> Enum.uniq_by(& &1.file)
      |> Enum.map(fn fragment ->
        source = fragment.source || ""

        File.new(fragment.file, source, %{
          package_id: package_id || fragment.package_id,
          package_version_id: package_version_id || fragment.package_version_id
        })
      end)

    if raw_files == [] do
      []
    else
      entries =
        Enum.map(raw_files, fn file ->
          file
          |> FileRecord.from_file()
          |> Map.merge(%{inserted_at: now, updated_at: now})
        end)

      SQL.bulk_insert_all(
        store.repo,
        files_source(store),
        entries,
        chunk_size: 2_000,
        conflict_target: [:package_version_id, :sha256],
        on_conflict: :nothing,
        timeout: :infinity
      )

      sha256s = Enum.map(raw_files, & &1.sha256)
      fetch_files_by_sha256(store, sha256s)
    end
  end

  defp fetch_files_by_sha256(store, sha256s) do
    from(f in files_source(store),
      where: f.sha256 in ^sha256s,
      select: {f.id, f.path, f.source, f.package_id, f.package_version_id, f.sha256}
    )
    |> store.repo.all()
    |> Enum.map(fn {id, path, source, package_id, package_version_id, sha256} ->
      %File{
        id: id,
        path: path,
        source: source,
        package_id: package_id,
        package_version_id: package_version_id,
        sha256: sha256,
        comments_text: ""
      }
    end)
  end

  defp upsert_fragments(store, fragments, now) do
    fragments_with_term_ids =
      Exograph.Hex.StageTimings.measure(:fragment_store_normalize_terms, fn ->
        normalize_terms(store, fragments)
      end)

    hashed = Enum.reject(fragments_with_term_ids, &is_nil(&1.content_hash))
    unhashed = Enum.filter(fragments_with_term_ids, &is_nil(&1.content_hash))

    hashed_unique = Enum.uniq_by(hashed, & &1.content_hash)

    {resolved_hashed, inserted_fragment_ids} =
      if hashed_unique != [] do
        entries =
          Exograph.Hex.StageTimings.measure(:fragment_store_build_fragment_rows, fn ->
            Enum.map(hashed_unique, fn fragment ->
              fragment
              |> FragmentRecord.from_fragment()
              |> Map.merge(%{inserted_at: now, updated_at: now})
            end)
          end)

        {hash_to_id, inserted_fragment_ids} =
          Exograph.Hex.StageTimings.measure(:fragment_store_resolve_fragment_ids, fn ->
            resolve_fragment_ids_by_hash(store, entries, hashed_unique)
          end)

        resolved_fragments =
          Enum.map(hashed, fn fragment ->
            %{fragment | id: Map.get(hash_to_id, fragment.content_hash)}
          end)

        {resolved_fragments, inserted_fragment_ids}
      else
        {[], MapSet.new()}
      end

    if unhashed != [] do
      entries =
        Exograph.Hex.StageTimings.measure(:fragment_store_build_fragment_rows, fn ->
          Enum.map(unhashed, fn fragment ->
            fragment
            |> FragmentRecord.from_fragment()
            |> Map.merge(%{inserted_at: now, updated_at: now})
          end)
        end)

      Exograph.Hex.StageTimings.measure(:fragment_store_insert_unhashed, fn ->
        SQL.bulk_insert_all(
          store.repo,
          {source(store), FragmentRecord},
          entries,
          on_conflict: :nothing,
          timeout: :infinity
        )
      end)
    end

    resolved = resolved_hashed ++ unhashed

    unless store.defer_fragment_terms? do
      Exograph.Hex.StageTimings.measure(:fragment_store_upsert_fragment_terms, fn ->
        upsert_fragment_terms(store, resolved, inserted_fragment_ids)
      end)
    end

    resolved
  end

  defp resolve_fragment_ids_by_hash(store, entries, hashed_unique) do
    inserted_by_hash = insert_fragments_by_hash(store, entries)

    missing_hashes =
      hashed_unique
      |> Enum.map(& &1.content_hash)
      |> Enum.reject(&Map.has_key?(inserted_by_hash, &1))

    hash_to_id =
      if missing_hashes == [] do
        inserted_by_hash
      else
        store.repo
        |> fragment_ids_by_hash(source(store), missing_hashes)
        |> Map.merge(inserted_by_hash)
      end

    inserted_fragment_ids =
      inserted_by_hash
      |> Map.values()
      |> MapSet.new()

    {hash_to_id, inserted_fragment_ids}
  end

  defp insert_fragments_by_hash(%{repo: repo} = store, entries) do
    if Exograph.Backend.duckdb_repo?(repo) do
      Exograph.DuckDB.FragmentAppend.insert_by_hash(repo, source(store), FragmentRecord, entries)
    else
      entries
      |> Enum.chunk_every(2_000)
      |> Enum.reduce(%{}, fn chunk, acc ->
        {_count, returning} =
          repo.insert_all(
            {source(store), FragmentRecord},
            chunk,
            conflict_target: [:content_hash],
            on_conflict: :nothing,
            returning: [:id, :content_hash],
            timeout: :infinity
          )

        Map.merge(acc, Map.new(returning, fn r -> {r.content_hash, r.id} end))
      end)
    end
  end

  defp fragment_ids_by_hash(repo, target_table, hashes) do
    from(f in {target_table, FragmentRecord},
      where: f.content_hash in ^hashes,
      select: {f.content_hash, f.id}
    )
    |> repo.all(timeout: :infinity)
    |> Map.new()
  end

  defp normalize_terms(store, fragments) do
    all_terms =
      fragments
      |> Enum.flat_map(fn f -> MapSet.to_list(f.terms) end)
      |> Enum.filter(&is_binary/1)
      |> Enum.uniq()

    if all_terms == [] do
      fragments
    else
      Exograph.Hex.StageTimings.measure(:fragment_store_upsert_terms, fn ->
        upsert_terms(store, all_terms)
      end)

      term_to_id =
        Exograph.Hex.StageTimings.measure(:fragment_store_load_term_ids, fn ->
          load_term_ids(store, all_terms)
        end)

      Enum.map(fragments, fn fragment ->
        if Enum.all?(MapSet.to_list(fragment.terms), &is_integer/1) do
          fragment
        else
          term_ids =
            fragment.terms
            |> MapSet.to_list()
            |> Enum.flat_map(fn term ->
              case Map.fetch(term_to_id, term) do
                {:ok, id} -> [id]
                :error -> []
              end
            end)
            |> MapSet.new()

          %{fragment | terms: term_ids}
        end
      end)
    end
  end

  defp upsert_fragment_terms(store, fragments, inserted_fragment_ids) do
    entries =
      fragments
      |> Enum.flat_map(fn fragment ->
        if is_integer(fragment.id) and MapSet.member?(inserted_fragment_ids, fragment.id) do
          fragment.terms
          |> MapSet.to_list()
          |> Enum.filter(&is_integer/1)
          |> Enum.map(&%{fragment_id: fragment.id, term_id: &1})
        else
          []
        end
      end)
      |> Enum.uniq()

    if entries != [] do
      source = Options.fragment_terms_source(store.prefix)

      Exograph.Hex.StageTimings.measure(:fragment_terms_bulk_insert, fn ->
        bulk_insert_fragment_terms(store, source, entries)
      end)
    end
  end

  defp bulk_insert_fragment_terms(%{repo: repo, postgres_copy?: true}, source, entries) do
    if Exograph.Backend.postgres_repo?(repo) do
      SQL.copy_integer_rows(repo, source, [:term_id, :fragment_id], entries)
    else
      bulk_insert_duckdb_or_postgres(repo, source, entries, chunk_size: 10_000)
    end
  end

  defp bulk_insert_fragment_terms(%{repo: repo}, source, entries) do
    bulk_insert_duckdb_or_postgres(repo, source, entries, chunk_size: 10_000)
  end

  defp bulk_insert_facts(repo, source, entries, opts) do
    bulk_insert_duckdb_or_postgres(repo, source, entries, opts)
  end

  defp bulk_insert_duckdb_or_postgres(repo, source, entries, opts) do
    if Exograph.Backend.duckdb_repo?(repo) do
      repo.insert_all(source, entries,
        insert_method: :append,
        chunk_every: Keyword.fetch!(opts, :chunk_size),
        timeout: :infinity
      )
    else
      SQL.bulk_insert_all(
        repo,
        source,
        entries,
        chunk_size: Keyword.fetch!(opts, :chunk_size),
        on_conflict: :nothing,
        timeout: :infinity
      )
    end
  end

  defp upsert_terms(store, terms) do
    entries = Enum.map(terms, &%{term: &1})
    source = terms_source(store)
    {table_name, _schema} = source

    if Exograph.Backend.duckdb_repo?(store.repo) do
      :global.trans(
        {{__MODULE__, store.repo, table_name}, self()},
        fn -> insert_term_chunks(store.repo, source, table_name, entries) end,
        [node()],
        1_000_000
      )
    else
      insert_term_chunks(store.repo, source, table_name, entries)
    end
  end

  defp insert_term_chunks(repo, source, table_name, entries) do
    entries
    |> Enum.chunk_every(1_000)
    |> Enum.each(fn chunk ->
      repo.transaction(fn ->
        lock_terms_table(repo, table_name)

        repo.insert_all(
          source,
          chunk,
          conflict_target: [:term],
          on_conflict: :nothing,
          timeout: :infinity
        )
      end)
    end)
  end

  defp lock_terms_table(repo, table_name) do
    if Exograph.Backend.postgres_repo?(repo) do
      repo.query!("SELECT pg_advisory_xact_lock(hashtext($1))", [table_name])
    end
  end

  defp load_term_ids(store, terms) do
    import Ecto.Query

    from(t in terms_source(store), where: t.term in ^terms, select: {t.term, t.id})
    |> store.repo.all(timeout: :infinity)
    |> Map.new()
  end

  defp upsert_code_facts(_store, [], _fragments, _now), do: :ok

  defp upsert_code_facts(store, files, fragments, now) do
    fragments_by_file_id = Enum.group_by(fragments, & &1.file_id)

    files_with_ast =
      Exograph.Hex.StageTimings.measure(:code_facts_parse_ast, fn ->
        Enum.map(files, fn file ->
          ast =
            case Exograph.ElixirParser.string_to_quoted(file.source || "",
                   line: 1,
                   columns: true,
                   emit_warnings: false
                 ) do
              {:ok, ast} -> ast
              _ -> nil
            end

          {file, ast}
        end)
      end)

    comments =
      Exograph.Hex.StageTimings.measure(:code_facts_extract_comments, fn ->
        files_with_ast
        |> Enum.flat_map(fn {file, _ast} ->
          comments = extract_comments(file.source || "")

          fragment_ids_by_line =
            Exograph.Hex.StageTimings.measure(:code_facts_locate_comments, fn ->
              fragment_ids_by_line(fragments_by_file_id[file.id], comments)
            end)

          Enum.map(comments, fn comment ->
            Comment.new(file, comment, Map.get(fragment_ids_by_line, comment.line))
          end)
        end)
      end)

    definitions =
      Exograph.Hex.StageTimings.measure(:code_facts_extract_definitions, fn ->
        files_with_ast
        |> Enum.flat_map(fn {file, ast} ->
          definitions = symbols_from(ast, file.source || "", &ExAST.Symbols.definitions/1)

          fragment_ids_by_line =
            Exograph.Hex.StageTimings.measure(:code_facts_locate_definitions, fn ->
              fragment_ids_by_line(fragments_by_file_id[file.id], definitions)
            end)

          Enum.map(definitions, fn definition ->
            Definition.new(file, definition, Map.get(fragment_ids_by_line, definition.line))
          end)
        end)
      end)

    references =
      Exograph.Hex.StageTimings.measure(:code_facts_extract_references, fn ->
        files_with_ast
        |> Enum.flat_map(fn {file, ast} ->
          references =
            ast
            |> symbols_from(file.source || "", &ExAST.Symbols.references/1)
            |> Enum.reject(&noise_reference?/1)

          fragment_ids_by_line =
            Exograph.Hex.StageTimings.measure(:code_facts_locate_references, fn ->
              fragment_ids_by_line(fragments_by_file_id[file.id], references)
            end)

          Enum.map(references, fn reference ->
            Reference.new(file, reference, Map.get(fragment_ids_by_line, reference.line))
          end)
        end)
      end)

    Exograph.Hex.StageTimings.measure(:code_facts_insert_comments, fn ->
      insert_code_facts(
        store,
        comments_source(store),
        comments,
        CommentRecord,
        :from_comment,
        now
      )
    end)

    Exograph.Hex.StageTimings.measure(:code_facts_insert_definitions, fn ->
      insert_code_facts(
        store,
        definitions_source(store),
        definitions,
        DefinitionRecord,
        :from_definition,
        now
      )
    end)

    Exograph.Hex.StageTimings.measure(:code_facts_insert_references, fn ->
      insert_code_facts(
        store,
        references_source(store),
        references,
        ReferenceRecord,
        :from_reference,
        now
      )
    end)

    if extractor_enabled?(store, :reach) do
      %{graph_nodes: graph_nodes, call_edges: call_edges} =
        Exograph.Hex.StageTimings.measure(:code_facts_extract_reach, fn ->
          ReachExtractor.extract_files(files, fragments_by_file_id)
        end)

      Exograph.Hex.StageTimings.measure(:code_facts_insert_reach, fn ->
        insert_graph_nodes_and_edges(store, graph_nodes, call_edges, now)
      end)
    end
  end

  defp insert_graph_nodes_and_edges(store, graph_nodes, call_edges, now) do
    if graph_nodes != [] do
      entries =
        Enum.map(graph_nodes, fn node ->
          GraphNodeRecord.from_graph_node(node)
          |> Map.merge(%{inserted_at: now, updated_at: now})
        end)

      gn_source = graph_nodes_source(store)

      SQL.bulk_insert_all(
        store.repo,
        gn_source,
        entries,
        chunk_size: 2_000,
        on_conflict: :nothing,
        timeout: :infinity
      )

      external_ids = graph_nodes |> Enum.map(& &1.external_id) |> Enum.reject(&is_nil/1)
      qualified_names = Enum.map(graph_nodes, & &1.qualified_name)

      db_nodes =
        from(n in gn_source,
          where: n.external_id in ^external_ids or n.qualified_name in ^qualified_names
        )
        |> store.repo.all()

      node_id_map = build_node_id_map(db_nodes, graph_nodes)

      if call_edges != [] do
        resolved_edges =
          Enum.map(call_edges, fn edge ->
            %{
              edge
              | caller_node_id: Map.get(node_id_map, edge.caller_node_id),
                callee_node_id: Map.get(node_id_map, edge.callee_node_id)
            }
          end)
          |> Enum.reject(fn e -> is_nil(e.caller_node_id) or is_nil(e.callee_node_id) end)

        insert_code_facts(
          store,
          call_edges_source(store),
          resolved_edges,
          CallEdgeRecord,
          :from_call_edge,
          now
        )
      end
    end
  end

  defp build_node_id_map(returning, original_nodes) do
    external_to_db = Map.new(returning, fn r -> {r.external_id, r.id} end)
    qualified_to_db = Map.new(returning, fn r -> {{r.qualified_name, r.kind}, r.id} end)

    Enum.reduce(original_nodes, %{}, fn node, acc ->
      db_id =
        Map.get(external_to_db, node.external_id) ||
          Map.get(qualified_to_db, {node.qualified_name, node.kind})

      if db_id, do: Map.put(acc, node.id, db_id), else: acc
    end)
  end

  defp extractor_enabled?(store, name) do
    Enum.any?(store.extractors, fn
      ^name -> true
      {^name, opts} -> Keyword.get(opts, :enabled?, true)
      _other -> false
    end)
  end

  defp extract_comments(source) do
    Exograph.File.comments(source)
  rescue
    _ -> []
  end

  defp symbols_from(nil, source, fun) do
    fun.(source)
  rescue
    _ -> []
  end

  defp symbols_from(ast, _source, fun) do
    fun.(ast)
  rescue
    _ -> []
  end

  defp noise_reference?(ref) do
    qualified_name = ref.qualified_name || ""

    MapSet.member?(@noise_references, qualified_name) or
      String.starts_with?(qualified_name, "__block__/") or
      String.contains?(qualified_name, "__exograph_unknown_atom__") or
      qualified_name in ["\\\\/2", "String.t/0"] or
      (ref.kind == :alias and qualified_name in ["String"]) or
      (ref.kind == :local_call and ref.name == "__block__")
  end

  defp fragment_ids_by_line(fragments, facts) do
    lines = Enum.map(facts, & &1.line)
    FragmentLocator.containing_fragment_ids(fragments, lines)
  end

  defp insert_code_facts(_store, _source, [], _record, _mapper, _now), do: :ok

  defp insert_code_facts(store, source, facts, record, mapper, now) do
    {build_stage, bulk_stage} = code_fact_insert_stages(mapper)

    entries =
      Exograph.Hex.StageTimings.measure(build_stage, fn ->
        Enum.map(facts, fn fact ->
          record
          |> apply(mapper, [fact])
          |> Map.merge(%{inserted_at: now, updated_at: now})
        end)
      end)

    Exograph.Hex.StageTimings.measure(bulk_stage, fn ->
      if store.duckdb_insert_buffer && Exograph.Backend.duckdb_repo?(store.repo) do
        Exograph.DuckDB.InsertBuffer.insert(store.duckdb_insert_buffer, source, entries)
      else
        bulk_insert_facts(store.repo, source, entries,
          chunk_size: code_fact_chunk_size(store.repo)
        )
      end
    end)
  end

  defp code_fact_chunk_size(repo) do
    if Exograph.Backend.duckdb_repo?(repo), do: 10_000, else: 3_000
  end

  defp code_fact_insert_stages(:from_comment),
    do: {:code_facts_build_comment_rows, :code_facts_bulk_insert_comments}

  defp code_fact_insert_stages(:from_definition),
    do: {:code_facts_build_definition_rows, :code_facts_bulk_insert_definitions}

  defp code_fact_insert_stages(:from_reference),
    do: {:code_facts_build_reference_rows, :code_facts_bulk_insert_references}

  defp code_fact_insert_stages(:from_call_edge),
    do: {:code_facts_build_call_edge_rows, :code_facts_bulk_insert_call_edges}

  defp package_from_version(%PackageVersion{} = version) do
    %Package{
      id: nil,
      ecosystem: version.ecosystem,
      name: version.package_name,
      metadata: %{}
    }
  end

  defp files_source(store), do: Options.files_source(store.prefix)
  defp comments_source(store), do: Options.comments_source(store.prefix)
  defp definitions_source(store), do: Options.definitions_source(store.prefix)
  defp references_source(store), do: Options.references_source(store.prefix)
  defp graph_nodes_source(store), do: Options.graph_nodes_source(store.prefix)
  defp call_edges_source(store), do: Options.call_edges_source(store.prefix)
  defp terms_source(store), do: Options.terms_source(store.prefix)
  defp source(store), do: Options.fragments_source(store.prefix)
end
