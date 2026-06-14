defmodule Exograph.FragmentLocatorTest do
  use ExUnit.Case, async: true

  alias Exograph.FragmentLocator

  test "bulk line lookup matches single lookup" do
    fragments = [
      %{id: 1, line: 1, end_line: 20, mass: 100},
      %{id: 2, line: 3, end_line: 7, mass: 10},
      %{id: 3, line: 5, end_line: 5, mass: 1},
      %{id: 4, line: 10, end_line: nil, mass: 5}
    ]

    lines = [1, 3, 5, 8, 10, 30, nil]

    bulk = FragmentLocator.containing_fragment_ids(fragments, lines)

    for line <- Enum.reject(lines, &is_nil/1) do
      assert Map.fetch!(bulk, line) == FragmentLocator.containing_fragment_id(fragments, line)
    end
  end
end
