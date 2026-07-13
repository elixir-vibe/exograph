defmodule Exograph.DSL.Sources do
  @moduledoc false

  alias Exograph.Storage.{
    CallEdgeRecord,
    DefinitionRecord,
    FileRecord,
    PackageRecord,
    PackageVersionRecord,
    ReferenceRecord,
    Schema
  }

  @package_fields MapSet.new([:id, :ecosystem, :name, :metadata])

  @package_version_fields MapSet.new([
                            :id,
                            :package_id,
                            :version,
                            :source_ref,
                            :checksum,
                            :index_state,
                            :metadata
                          ])

  @file_fields MapSet.new([
                 :id,
                 :package_id,
                 :package_version_id,
                 :path,
                 :comments_text,
                 :identifier_tokens,
                 :sha256
               ])

  @symbol_fact_fields MapSet.new([
                        :id,
                        :package_id,
                        :package_version_id,
                        :file_id,
                        :fragment_id,
                        :kind,
                        :module,
                        :name,
                        :arity,
                        :qualified_name,
                        :line,
                        :column
                      ])

  @fragment_fields MapSet.new([
                     :id,
                     :package_id,
                     :package_version_id,
                     :file_id,
                     :kind,
                     :module,
                     :name,
                     :arity,
                     :line,
                     :end_line,
                     :mass
                   ])

  @call_edge_fields MapSet.new([
                      :id,
                      :package_id,
                      :package_version_id,
                      :file_id,
                      :caller_node_id,
                      :callee_node_id,
                      :call_site_fragment_id,
                      :caller_qualified_name,
                      :callee_qualified_name,
                      :line,
                      :column
                    ])

  def source(:package, prefix), do: Schema.packages_source(prefix)
  def source(:package_version, prefix), do: Schema.package_versions_source(prefix)
  def source(:file, prefix), do: Schema.files_source(prefix)
  def source(:definition, prefix), do: Schema.definitions_source(prefix)
  def source(:reference, prefix), do: Schema.references_source(prefix)
  def source(:call_edge, prefix), do: Schema.call_edges_source(prefix)

  def source_record(:package), do: PackageRecord
  def source_record(:package_version), do: PackageVersionRecord
  def source_record(:file), do: FileRecord
  def source_record(:definition), do: DefinitionRecord
  def source_record(:reference), do: ReferenceRecord
  def source_record(:call_edge), do: CallEdgeRecord

  def primary_source(:definitions, prefix), do: Schema.definitions_source(prefix)
  def primary_source(:references, prefix), do: Schema.references_source(prefix)
  def primary_source(:calls, prefix), do: Schema.call_edges_source(prefix)

  def join_source(:definitions, prefix), do: Schema.definitions_source(prefix)
  def join_source(:references, prefix), do: Schema.references_source(prefix)
  def join_source(:calls, prefix), do: Schema.call_edges_source(prefix)

  def fields(:package), do: @package_fields
  def fields(:package_version), do: @package_version_fields
  def fields(:file), do: @file_fields
  def fields(:fragment), do: @fragment_fields
  def fields(:definition), do: @symbol_fact_fields
  def fields(:reference), do: @symbol_fact_fields
  def fields(:definitions), do: @symbol_fact_fields
  def fields(:references), do: @symbol_fact_fields
  def fields(:call_edge), do: @call_edge_fields
  def fields(:calls), do: @call_edge_fields

  def assert_field!(source, field) do
    unless MapSet.member?(fields(source), field) do
      raise ArgumentError, "unsupported #{source} field in Exograph DSL: #{field}"
    end
  end
end
