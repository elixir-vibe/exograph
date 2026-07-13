defmodule Exograph.API.ErrorResponseTest do
  use ExUnit.Case, async: true

  alias Exograph.API.ErrorResponse

  test "round-trips the versioned error envelope" do
    response = ErrorResponse.new("invalid_query", "query is invalid", %{"field" => "source"})

    assert %{
             "version" => 1,
             "error" => %{
               "code" => "invalid_query",
               "message" => "query is invalid",
               "details" => %{"field" => "source"}
             }
           } = encoded = JSONCodec.dump(response)

    assert {:ok, ^response} = ErrorResponse.from_map(encoded)
  end
end
