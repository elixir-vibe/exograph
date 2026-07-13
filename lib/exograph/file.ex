defmodule Exograph.File do
  @moduledoc """
  Source file stored once per package version.
  """

  use JSONCodec

  @type t :: %__MODULE__{
          id: integer() | nil,
          package_id: integer() | nil,
          package_version_id: integer() | nil,
          path: String.t(),
          source: String.t(),
          ast: any(),
          comments_text: String.t(),
          identifier_tokens: String.t(),
          sha256: String.t()
        }

  defstruct [
    :id,
    :package_id,
    :package_version_id,
    :path,
    :source,
    :ast,
    :comments_text,
    :identifier_tokens,
    :sha256
  ]

  def new(path, source, context \\ %{}) do
    sha256 = :crypto.hash(:sha256, source) |> Base.encode16(case: :lower)

    %__MODULE__{
      id: nil,
      package_id: Map.get(context, :package_id),
      package_version_id: Map.get(context, :package_version_id),
      path: path,
      source: source,
      ast: Map.get(context, :ast),
      comments_text: comments_text(source),
      identifier_tokens: Exograph.IdentifierTokens.from_source(source),
      sha256: sha256
    }
  end

  def comments_text(source) do
    source
    |> comments()
    |> Enum.map_join("\n", & &1.text)
  rescue
    ArgumentError -> ""
  end

  def comments(source) do
    {:ok, _ast, comments} =
      Exograph.ElixirParser.string_to_quoted_with_comments(source, emit_warnings: false)

    Enum.map(comments, fn comment ->
      %ExAST.Comment{
        text: Map.get(comment, :text, ""),
        line: Map.get(comment, :line),
        column: Map.get(comment, :column),
        previous_eol_count: Map.get(comment, :previous_eol_count),
        next_eol_count: Map.get(comment, :next_eol_count)
      }
    end)
  end
end
