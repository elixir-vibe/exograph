defmodule Exograph.OptionalDependencyCompileTest do
  use ExUnit.Case, async: false

  test "project compilers omit phoenix_iconify when the compiler module is absent" do
    script = """
    Mix.start()
    Code.require_file("mix.exs")
    compilers = Exograph.MixProject.project()[:compilers]
    if :phoenix_iconify in compilers, do: System.halt(1), else: System.halt(0)
    """

    assert {_, 0} = run_elixir_without_optional_web_deps(script)
  end

  test "web helpers and rate limiter compile without hammer and phoenix_iconify" do
    script = """
    Code.compile_file("lib/exograph/web.ex")
    Code.compile_file("lib/exograph/web/rate_limiter.ex")

    unless function_exported?(Exograph.Web, :icon, 1) do
      IO.puts("missing Exograph.Web.icon/1")
      System.halt(1)
    end

    unless Exograph.Web.RateLimiter.start_link([]) == :ignore do
      IO.puts("unexpected rate limiter start_link result")
      System.halt(1)
    end

    unless Exograph.Web.RateLimiter.hit("key", 1_000, 60) == {:allow, 0} do
      IO.puts("unexpected rate limiter hit result")
      System.halt(1)
    end
    """

    assert {_, 0} = run_elixir_without_optional_web_deps(script)
  end

  test "web task reports missing optional web dependencies before runtime crashes" do
    script = """
    Mix.start()
    Code.compile_file("lib/mix/tasks/exograph.web.ex")

    try do
      Mix.Tasks.Exograph.Web.run([])
    rescue
      error in Mix.Error ->
        message = Exception.message(error)

        if message =~ "mix exograph.web requires these dependencies" and message =~ "volt" do
          System.halt(0)
        else
          IO.puts(message)
          System.halt(1)
        end
    else
      _ ->
        IO.puts("expected Mix.Error")
        System.halt(1)
    end
    """

    assert {_, 0} = run_elixir_without_optional_web_deps(script, reject: ["volt"])
  end

  defp run_elixir_without_optional_web_deps(script, opts \\ []) do
    extra_rejects = Keyword.get(opts, :reject, [])

    code_path_args =
      :code.get_path()
      |> Enum.reject(fn path ->
        path = List.to_string(path)

        String.contains?(path, "/hammer-") or
          String.contains?(path, "/phoenix_iconify-") or
          Enum.any?(extra_rejects, &String.contains?(path, "/#{&1}-")) or
          Enum.any?(extra_rejects, &String.contains?(path, "/_build/test/lib/#{&1}/ebin")) or
          String.ends_with?(path, "/_build/test/lib/hammer/ebin") or
          String.ends_with?(path, "/_build/test/lib/phoenix_iconify/ebin") or
          String.ends_with?(path, "/_build/test/lib/exograph/ebin")
      end)
      |> Enum.flat_map(fn path -> ["-pa", List.to_string(path)] end)

    System.cmd("elixir", code_path_args ++ ["-e", script],
      cd: Keyword.get(opts, :cd, File.cwd!()),
      stderr_to_stdout: true
    )
  end
end
