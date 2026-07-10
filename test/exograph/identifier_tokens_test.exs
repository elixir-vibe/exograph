defmodule Exograph.IdentifierTokensTest do
  use ExUnit.Case, async: true

  alias Exograph.IdentifierTokens

  test "normalizes qualified, snake_case, camelCase, and bang identifiers" do
    assert IdentifierTokens.from_source("Repo.get! MyApp.handle_event handleEvent") ==
             "repo get my app handle event"
  end
end
