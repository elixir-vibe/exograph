Mix.install([{:skia, "~> 0.1.1"}])

alias Skia.Shader

project_root = File.cwd!()
output = Path.join(project_root, "priv/static/social/exograph-card.png")

card =
  Skia.canvas(1200, 630)
  |> Skia.rect(
    x: 0,
    y: 0,
    width: 1200,
    height: 630,
    fill: Shader.linear_gradient({0, 0}, {1200, 630}, ["#09090b", "#18181b", "#3b0764"])
  )
  |> Skia.rect(
    x: 56,
    y: 56,
    width: 1088,
    height: 518,
    radius: 32,
    stroke: "#8b5cf6",
    stroke_width: 3
  )
  |> Skia.text("Exograph", x: 96, y: 154, size: 34, weight: 700, fill: "#c4b5fd")
  |> Skia.text("Elixir package", x: 96, y: 286, size: 76, weight: 800, fill: "#fafafa")
  |> Skia.text("code search", x: 96, y: 374, size: 76, weight: 800, fill: "#fafafa")
  |> Skia.text("structural queries · text search · call graph facts",
    x: 96,
    y: 482,
    size: 30,
    fill: "#d4d4d8"
  )

{:ok, png} = Skia.to_png(card)
File.mkdir_p!(Path.dirname(output))
File.write!(output, png)
IO.puts("wrote #{Path.relative_to_cwd(output)}")
