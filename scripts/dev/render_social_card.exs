Mix.install([{:skia, "~> 0.1.1"}])

project_root = File.cwd!()
output = Path.join(project_root, "priv/static/social/exograph-card.png")

text = fn document, value, opts ->
  {fill, opts} = Keyword.pop(opts, :fill, :black)
  {:ok, blob} = Skia.TextBlob.new(value, opts)
  Skia.text_blob(document, blob, Keyword.put(opts, :fill, fill))
end

card =
  Skia.canvas(1200, 630)
  |> Skia.rect(x: 0, y: 0, width: 1200, height: 630, fill: "#faf7f0")
  |> Skia.rect(x: 56, y: 56, width: 1088, height: 518, stroke: "#ded6cb", stroke_width: 2)
  |> text.("search.elixir.toys", x: 92, y: 150, size: 38, fill: "#5b2bbf")
  |> text.("Exograph", x: 92, y: 288, size: 82, fill: "#171411")
  |> text.("Elixir code search", x: 92, y: 382, size: 82, fill: "#171411")
  |> Skia.rect(x: 92, y: 432, width: 430, height: 3, fill: "#5b2bbf")
  |> text.("Structural queries / Text search / Call graph facts",
    x: 92,
    y: 512,
    size: 30,
    fill: "#6f6860"
  )

{:ok, png} = Skia.to_png(card)
File.mkdir_p!(Path.dirname(output))
File.write!(output, png)
IO.puts("wrote #{Path.relative_to_cwd(output)}")
