defmodule Exograph.Web.Highlighter do
  @moduledoc false

  def highlight(source, line, context_lines \\ 2) when is_binary(source) and is_integer(line) do
    lines = String.split(source, "\n")
    start = max(line - context_lines - 1, 0)
    finish = min(line + context_lines - 1, length(lines) - 1)

    lines
    |> Enum.with_index(1)
    |> Enum.slice(start..finish)
    |> Enum.map(fn {text, line_num} ->
      html = highlight_line(text)
      {line_num, html, line_num == line}
    end)
  end

  @makeup_available Code.ensure_loaded?(Makeup) and Code.ensure_loaded?(Makeup.Lexers.ElixirLexer)

  @doc false
  def highlight_line(text) do
    if @makeup_available do
      Makeup.highlight_inner_html(text, lexer: Makeup.Lexers.ElixirLexer)
    else
      Phoenix.HTML.html_escape(text) |> Phoenix.HTML.safe_to_string()
    end
  rescue
    ArgumentError -> Phoenix.HTML.html_escape(text) |> Phoenix.HTML.safe_to_string()
  end
end
