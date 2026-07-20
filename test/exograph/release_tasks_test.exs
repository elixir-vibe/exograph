defmodule Exograph.ReleaseTasksTest do
  use ExUnit.Case, async: false

  alias Exograph.ReleaseTasks

  setup do
    previous = System.get_env("EXOGRAPH_MAX_INDEX_ERRORS")

    on_exit(fn ->
      if previous do
        System.put_env("EXOGRAPH_MAX_INDEX_ERRORS", previous)
      else
        System.delete_env("EXOGRAPH_MAX_INDEX_ERRORS")
      end
    end)

    :ok
  end

  test "validate_index_result! refuses to publish package errors by default" do
    System.delete_env("EXOGRAPH_MAX_INDEX_ERRORS")

    result = %{
      error: 1,
      failures: [%{name: "bad", version: "1.0.0", reason: ":commit_timeout"}]
    }

    assert_raise RuntimeError, ~r/refusing to publish staged index/, fn ->
      ReleaseTasks.validate_index_result!(result, %{build_dir: "/tmp/staged-index"})
    end
  end

  test "validate_index_result! allows explicitly configured error threshold" do
    System.put_env("EXOGRAPH_MAX_INDEX_ERRORS", "1")

    result = %{
      error: 1,
      failures: [%{name: "bad", version: "1.0.0", reason: ":commit_timeout"}]
    }

    assert :ok = ReleaseTasks.validate_index_result!(result, %{build_dir: "/tmp/staged-index"})
  end

  test "staged publication leaves the live artifacts unchanged when the build is incomplete" do
    paths = publication_paths()
    File.write!(paths.final_manifest, "live manifest")
    File.write!(paths.final_report, "live report")
    File.write!(paths.staged_manifest, "staged manifest")

    build = %{manifest_path: paths.staged_manifest, report_path: paths.staged_report}

    assert_raise RuntimeError, ~r/staged index artifact is missing/, fn ->
      ReleaseTasks.publish_staged_build!(build, paths.final_manifest, paths.final_report)
    end

    assert File.read!(paths.final_manifest) == "live manifest"
    assert File.read!(paths.final_report) == "live report"
  end

  test "staged publication commits the manifest after preparing both artifacts" do
    paths = publication_paths()
    File.write!(paths.final_manifest, "live manifest")
    File.write!(paths.final_report, "live report")
    File.write!(paths.staged_manifest, "staged manifest")
    File.write!(paths.staged_report, "staged report")

    build = %{manifest_path: paths.staged_manifest, report_path: paths.staged_report}

    assert :ok =
             ReleaseTasks.publish_staged_build!(build, paths.final_manifest, paths.final_report)

    assert File.read!(paths.final_manifest) == "staged manifest"
    assert File.read!(paths.final_report) == "staged report"
    assert Path.wildcard(Path.join(paths.root, "**/*.tmp-*")) == []
  end

  defp publication_paths do
    root =
      Path.join(
        System.tmp_dir!(),
        "exograph-staged-publication-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)

    %{
      root: root,
      staged_manifest: Path.join(root, "build/hex-manifest.term"),
      staged_report: Path.join(root, "build/index-report.json"),
      final_manifest: Path.join(root, "live/hex-manifest.term"),
      final_report: Path.join(root, "live/index-report.json")
    }
    |> tap(fn paths ->
      File.mkdir_p!(Path.dirname(paths.staged_manifest))
      File.mkdir_p!(Path.dirname(paths.final_manifest))
    end)
  end
end
