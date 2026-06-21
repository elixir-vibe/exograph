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
            ~s|from(d in Definition, where: d.kind == :def, where: prefix_search(d.name, "handle"), limit: 5)|
        })

      assert resp.status == 200
      body = json_body(resp)
      assert body["count"] > 0
      assert hd(body["results"])["type"] == "definition"
      assert body["meta"]["limit"] == 5
      assert body["meta"]["returned"] == body["count"]
      assert body["meta"]["shards"]["total"] >= 1
    end

    test "rejects dangerous code" do
      resp = api_post("/api/query", %{query: ~s|System.cmd("ls", [])|})

      assert resp.status == 400
      body = json_body(resp)
      assert body["error"]["message"] =~ "Expected from"
    end

    test "returns parse error for invalid syntax" do
      resp = api_post("/api/query", %{query: "from(f in Fragment"})

      assert resp.status == 400
      body = json_body(resp)
      assert body["error"]["message"] =~ "missing terminator"
    end
  end

  describe "GET /api/stats" do
    test "returns index statistics" do
      body = api_get("/api/stats") |> json_body()

      assert is_integer(body["packages"])
      assert is_integer(body["fragments"])
      assert is_integer(body["definitions"])
      assert is_integer(body["references"])
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
