defmodule Exograph.Features.APITest do
  use Exograph.APICase

  @moduletag :feature

  defp first_package_id do
    body = api_get("/api/packages") |> json_body()
    hd(body["packages"])["id"]
  end

  describe "POST /api/search" do
    test "returns results for valid pattern" do
      resp = api_post("/api/search", %{pattern: "def _ do ... end", limit: 5})

      assert resp.status == 200
      body = json_body(resp)
      assert body["count"] > 0
      assert length(body["results"]) <= 5
      assert is_float(body["elapsed_ms"])

      result = hd(body["results"])
      assert result["kind"]
      assert result["line"]
      assert Map.has_key?(result, "package_version")
    end

    test "returns next_cursor when more results available" do
      resp = api_post("/api/search", %{pattern: "def _ do ... end", limit: 2})

      body = json_body(resp)
      assert body["count"] == 2
      assert body["next_cursor"]
    end

    test "cursor pagination returns different results" do
      page1 = api_post("/api/search", %{pattern: "def _ do ... end", limit: 3}) |> json_body()

      page2 =
        api_post("/api/search", %{
          pattern: "def _ do ... end",
          limit: 3,
          cursor: page1["next_cursor"]
        })
        |> json_body()

      page1_lines = Enum.map(page1["results"], & &1["line"])
      page2_lines = Enum.map(page2["results"], & &1["line"])
      assert page1_lines != page2_lines
    end

    test "malformed cursor falls back to first page" do
      first_page =
        api_post("/api/search", %{pattern: "def _ do ... end", limit: 2}) |> json_body()

      malformed_cursor_page =
        api_post("/api/search", %{
          pattern: "def _ do ... end",
          limit: 2,
          cursor: Base.url_encode64("not-an-integer", padding: false)
        })
        |> json_body()

      assert malformed_cursor_page["results"] == first_page["results"]
    end

    test "expands structural predicate shorthand" do
      resp =
        api_post("/api/search", %{
          pattern: ~s|matches(f, def handle_call(_, _, _) do ... end)|,
          limit: 5
        })

      assert resp.status == 200
      body = json_body(resp)
      assert body["count"] > 0
      assert body["count"] <= 5
      assert body["meta"]["limit"] == 5
    end

    test "executes DSL query patterns" do
      resp =
        api_post("/api/search", %{
          pattern:
            ~s|from(f in Fragment, where: matches(f, "def handle_call(_, _, _) do ... end"), limit: 20)|,
          limit: 20
        })

      assert resp.status == 200
      body = json_body(resp)
      assert body["count"] > 0
      assert length(body["results"]) <= 20
      assert body["meta"]["total"]["relation"] == "eq"
      assert body["meta"]["total"]["value"] >= body["count"]

      notice_kinds = Enum.map(body["meta"]["notices"], & &1["kind"])
      refute "truncated" in notice_kinds
      refute "more_results" in notice_kinds
    end

    test "limits results to requested limit" do
      resp = api_post("/api/search", %{pattern: "def _ do ... end", limit: 1})

      body = json_body(resp)
      assert body["count"] == 1
      assert length(body["results"]) == 1
    end
  end

  describe "POST /api/query" do
    test "executes DSL query" do
      resp =
        api_post("/api/query", %{
          query:
            ~s|from(d in Definition, where: d.kind == :def, where: prefix_search(d.name, "handle"), limit: 1)|
        })

      assert resp.status == 200
      body = json_body(resp)
      assert body["count"] > 0
      assert hd(body["results"])["type"] == "definition"
      assert body["count"] == 1
      assert body["meta"]["limit"] == 1
      assert body["meta"]["returned"] == body["count"]
      assert body["meta"]["total"] == %{"relation" => "gte", "value" => 1}
      assert body["meta"]["shards"]["total"] >= 1
    end

    test "executes versioned query objects" do
      resp =
        api_post("/api/query", %{
          query: %{
            version: 1,
            source: "definition",
            binding: "d",
            predicates: [
              %{op: "prefix_search", binding: "d", field: "name", value: "handle"}
            ],
            joins: []
          }
        })

      assert resp.status == 200
      body = json_body(resp)
      assert body["count"] > 0
      assert hd(body["results"])["type"] == "definition"
    end

    test "rejects dangerous code" do
      resp = api_post("/api/query", %{query: ~s|System.cmd("ls", [])|})

      assert resp.status == 400
      body = json_body(resp)
      assert body["version"] == 1
      assert body["error"]["code"] == "invalid_query"
      assert body["error"]["message"] =~ "Expected from"
    end

    test "returns parse error for invalid syntax" do
      resp = api_post("/api/query", %{query: "from(f in Fragment"})

      assert resp.status == 400
      body = json_body(resp)
      assert body["error"]["message"] =~ "missing terminator"
    end
  end

  describe "POST /api/plan" do
    test "returns a versioned logical plan" do
      body =
        api_post("/api/plan", %{
          query: %{
            version: 1,
            source: "fragment",
            binding: "f",
            predicates: [%{op: "contains", binding: "f", value: "Enum.map(_, _)"}],
            joins: []
          }
        })
        |> json_body()

      assert body["version"] == 1
      assert body["plan"]["execution"] == "indexed_structural"
      assert body["plan"]["hydration"] == "indexed_fragments"
      assert body["estimate"]["relation"] in ["eq", "gte"]
      assert is_integer(body["estimate"]["value"])
      assert body["index"]["kind"] == "single"
    end

    test "rejects unsupported query versions with the public error envelope" do
      resp =
        api_post("/api/plan", %{
          query: %{version: 2, source: "package", binding: "p", predicates: [], joins: []}
        })

      assert resp.status == 400
      body = json_body(resp)
      assert body["version"] == 1
      assert body["error"]["code"] == "invalid_query"
      assert body["error"]["message"] =~ "unsupported_query_version"
    end
  end

  describe "POST /api/query with public entities" do
    test "serializes package results through JSONCodec" do
      body =
        api_post("/api/query", %{
          query: %{version: 1, source: "package", binding: "p", predicates: [], joins: []}
        })
        |> json_body()

      assert [%{"name" => "feature_fixture", "ecosystem" => "hex"}] = body["results"]
    end
  end

  describe "POST /api/hydrate" do
    test "returns a package-version source snapshot" do
      body =
        api_post("/api/hydrate", %{
          packageName: "feature_fixture",
          version: "1.0.0",
          paths: ["**"]
        })
        |> json_body()

      assert body["package_version"]["package_name"] == "feature_fixture"
      assert body["complete"]
      assert is_binary(body["fingerprint"])
      assert length(body["files"]) == 1
    end
  end

  describe "POST /api/hydrate validation" do
    test "rejects unsafe snapshot paths with the public error envelope" do
      resp =
        api_post("/api/hydrate", %{
          packageName: "feature_fixture",
          version: "1.0.0",
          paths: ["../**"]
        })

      assert resp.status == 400
      body = json_body(resp)
      assert body["version"] == 1
      assert body["error"]["code"] == "invalid_hydration_request"
    end
  end

  describe "GET /api/capabilities" do
    test "returns versioned query capabilities" do
      body = api_get("/api/capabilities") |> json_body()

      assert body["version"] == 1
      assert body["api_version"] == 1
      assert body["error_version"] == 1
      assert "plan" in body["endpoints"]
      assert "package_version" in body["sources"]
      assert "matches" in body["predicates"]
      assert body["hydration"] == ["package_version"]
      assert body["hydration_limits"]["max_files"] > 0
      assert body["hydration_limits"]["max_bytes"] > 0
    end
  end

  describe "GET /api/health" do
    test "returns runtime and index metadata" do
      body = api_get("/api/health") |> json_body()

      assert body["status"] == "ok"
      assert body["application"]["name"] == "exograph"
      assert body["application"]["version"]
      assert body["index"]["kind"]
      assert is_integer(body["index"]["opened_shards"])
      assert body["runtime"]["prefix"]
    end
  end

  describe "GET /api/stats" do
    test "returns index statistics" do
      body = api_get("/api/stats") |> json_body()

      assert is_integer(body["packages"])
      assert is_integer(body["fragments"])
      assert is_integer(body["definitions"])
      assert is_integer(body["references"])
      refute Map.has_key?(body, "poisoned_structural_names")
      assert body["prefix"]
    end
  end

  describe "GET /api/packages" do
    test "returns package list" do
      body = api_get("/api/packages") |> json_body()

      assert is_integer(body["total"])
      assert is_list(body["packages"])

      if body["total"] > 0 do
        pkg = hd(body["packages"])
        assert pkg["id"]
        assert pkg["name"]
        assert is_integer(pkg["fragments"])
      end
    end
  end

  describe "POST /api/search text mode" do
    test "returns text search results" do
      resp =
        api_post(
          "/api/search",
          %{pattern: "defmodule", mode: "text", limit: 3, package_id: first_package_id()},
          timeout: 60_000
        )

      assert resp.status == 200
      body = json_body(resp)
      assert body["count"] > 0
      assert body["count"] <= 3
    end

    test "returns regex search results" do
      resp =
        api_post(
          "/api/search",
          %{pattern: "def \\w+!", mode: "regex", limit: 3, package_id: first_package_id()},
          timeout: 60_000
        )

      assert resp.status == 200
      body = json_body(resp)
      assert body["count"] > 0
    end

    test "returns error for invalid regex" do
      resp = api_post("/api/search", %{pattern: "[", mode: "regex", limit: 3})

      assert resp.status == 400
    end
  end

  describe "rate limiting" do
    test "includes rate limit headers" do
      resp = api_post("/api/search", %{pattern: "def _ do ... end", limit: 1})

      limit = Req.Response.get_header(resp, "x-ratelimit-limit")
      remaining = Req.Response.get_header(resp, "x-ratelimit-remaining")
      assert limit != []
      assert remaining != []
    end
  end
end
