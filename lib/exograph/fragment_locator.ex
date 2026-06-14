defmodule Exograph.FragmentLocator do
  @moduledoc false

  def containing_fragment_id(nil, _line), do: nil
  def containing_fragment_id(_fragments, nil), do: nil

  def containing_fragment_id(fragments, line) do
    case containing_fragment(fragments, line) do
      nil -> nil
      fragment -> fragment.id
    end
  end

  def containing_fragment_ids(nil, _lines), do: %{}

  def containing_fragment_ids(fragments, lines) do
    lines
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.sort()
    |> do_containing_fragment_ids(normalize_fragments(fragments), :gb_sets.empty())
  end

  defp do_containing_fragment_ids([], _fragments, _active), do: %{}

  defp do_containing_fragment_ids(lines, fragments, active) do
    {result, _fragments, _active} =
      Enum.reduce(lines, {%{}, fragments, active}, fn line, {acc, remaining, active} ->
        {starting, remaining} = Enum.split_while(remaining, &(&1.line <= line))

        active =
          starting
          |> Enum.reduce(active, fn fragment, active ->
            :gb_sets.add(active_key(fragment), active)
          end)
          |> prune_expired(line)

        {Map.put(acc, line, active_id(active)), remaining, active}
      end)

    result
  end

  defp normalize_fragments(fragments) do
    fragments
    |> Enum.reject(&is_nil(&1.line))
    |> Enum.with_index()
    |> Enum.map(fn {fragment, index} ->
      %{
        line: fragment.line,
        end_line: end_line(fragment),
        mass: fragment.mass,
        id: fragment.id,
        index: index
      }
    end)
    |> Enum.sort_by(& &1.line)
  end

  defp active_key(fragment) do
    {fragment.mass, fragment.index, fragment.end_line, fragment.id}
  end

  defp prune_expired(active, line) do
    if :gb_sets.is_empty(active) do
      active
    else
      {_mass, _index, end_line, _id} = key = :gb_sets.smallest(active)

      if end_line < line do
        key
        |> :gb_sets.delete(active)
        |> prune_expired(line)
      else
        active
      end
    end
  end

  defp active_id(active) do
    if :gb_sets.is_empty(active) do
      nil
    else
      {_mass, _index, _end_line, id} = :gb_sets.smallest(active)
      id
    end
  end

  defp containing_fragment(fragments, line) do
    fragments
    |> Enum.filter(&contains_line?(&1, line))
    |> Enum.min_by(& &1.mass, fn -> nil end)
  end

  defp contains_line?(fragment, line) do
    fragment.line <= line and end_line(fragment) >= line
  end

  defp end_line(%{end_line: nil}), do: 9_223_372_036_854_775_807
  defp end_line(%{end_line: end_line}), do: end_line
end
