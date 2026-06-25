defmodule Exograph.DuckDB.OfflineBuild do
  @moduledoc """
  Compatibility shim for the removed offline staging pipeline.

  Exograph now routes `:offline` build requests through the ordinary Ecto/QuackDB
  write path so storage code does not own raw DuckDB SQL assembly. These functions
  remain only to avoid breaking older internal call sites while callers migrate to
  the online path.
  """

  def stage_table(prefix), do: stage_table(prefix, :fragment)
  def file_stage_table(prefix), do: stage_table(prefix, :file)
  def definition_stage_table(prefix), do: stage_table(prefix, :definition)
  def reference_stage_table(prefix), do: stage_table(prefix, :reference)
  def comment_stage_table(prefix), do: stage_table(prefix, :comment)
  def term_stage_table(prefix), do: stage_table(prefix, :term)
  def fragment_term_stage_table(prefix), do: stage_table(prefix, :fragment_term)
  def graph_node_stage_table(prefix), do: stage_table(prefix, :graph_node)
  def call_edge_stage_table(prefix), do: stage_table(prefix, :call_edge)

  def create_stages!(_repo, _prefix), do: :ok
  def finalize!(_repo, _prefix), do: removed_return(%{})
  def finalize_files!(_repo, _prefix), do: removed_return(%{})
  def finalize_fragments!(_repo, _prefix), do: removed_return(%{})
  def finalize_terms!(_repo, _prefix), do: removed_return(%{})
  def finalize_fragment_terms!(_repo, _prefix), do: removed_return(:ok)
  def finalize_graph_nodes!(_repo, _prefix), do: removed_return(:ok)
  def finalize_call_edges!(_repo, _prefix), do: removed_return(:ok)

  def append_file_stage!(_repo, _prefix, _rows), do: removed_return({0, []})
  def append_stage!(_repo, _prefix, _rows), do: removed_return({0, []})
  def append_definition_stage!(_repo, _prefix, _rows), do: removed_return({0, []})
  def append_reference_stage!(_repo, _prefix, _rows), do: removed_return({0, []})
  def append_comment_stage!(_repo, _prefix, _rows), do: removed_return({0, []})
  def append_term_stage!(_repo, _prefix, _rows), do: removed_return({0, []})
  def append_fragment_term_stage!(_repo, _prefix, _rows), do: removed_return({0, []})
  def append_graph_node_stage!(_repo, _prefix, _rows), do: removed_return({0, []})
  def append_call_edge_stage!(_repo, _prefix, _rows), do: removed_return({0, []})

  defp stage_table(prefix, kind), do: "#{prefix}_#{kind}_stage"

  defp removed_return(fallback) do
    Application.get_env(:exograph, :offline_build_removed_return, fallback)
  end
end
