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
end
