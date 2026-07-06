defmodule Exograph.AST.Locator do
  @moduledoc false

  def index(ast) do
    {_ast, next, entries} = do_index(ast, 1, [])
    %{entries: Enum.reverse(entries), size: next - 1}
  end

  def locate(%{entries: entries}, target) when is_list(entries) do
    locate_in_entries(entries, target)
  end

  def locate(ast, target) do
    ast
    |> index()
    |> locate(target)
  end

  defp locate_in_entries(entries, target) do
    key = key(target)

    case Enum.find(entries, fn entry -> entry.key == key end) do
      %{pre: pre, post: post} ->
        {pre, post}

      nil ->
        locate_synthetic_block(entries, target)
    end
  end

  defp locate_synthetic_block(entries, {:__block__, _meta, children}) when is_list(children) do
    located = Enum.map(children, &locate_in_entries(entries, &1))

    if Enum.all?(located, fn {pre, post} -> is_integer(pre) and is_integer(post) end) do
      {pres, posts} = Enum.unzip(located)
      {Enum.min(pres), Enum.max(posts)}
    else
      {nil, nil}
    end
  end

  defp locate_synthetic_block(_entries, _target), do: {nil, nil}

  def slice(ast, nil, nil), do: ast

  def slice(ast, pre, post) when is_integer(pre) and is_integer(post) do
    entries = index(ast).entries

    case Enum.find(entries, &(&1.pre == pre and &1.post == post)) do
      %{node: node} -> node
      nil -> block_for_interval(entries, pre, post)
    end
  end

  defp block_for_interval(entries, pre, post) do
    nodes =
      entries
      |> Enum.filter(&(&1.pre >= pre and &1.post <= post))
      |> Enum.reject(fn entry ->
        Enum.any?(entries, fn other ->
          other.pre >= pre and other.post <= post and other.pre < entry.pre and
            other.post > entry.post
        end)
      end)
      |> Enum.sort_by(& &1.pre)
      |> Enum.map(& &1.node)

    case nodes do
      [node] -> node
      many -> {:__block__, [], many}
    end
  end

  defp do_index({form, meta, args}, pre, acc) when is_list(args) do
    {args, next, acc} = do_index_list(args, pre + 1, acc)
    node = {form, meta, args}
    post = next
    {node, post + 1, [entry(node, pre, post) | acc]}
  end

  defp do_index({left, right} = node, pre, acc) do
    {_left, next, acc} = do_index(left, pre + 1, acc)
    {_right, next, acc} = do_index(right, next, acc)
    post = next
    {node, post + 1, [entry(node, pre, post) | acc]}
  end

  defp do_index(list, pre, acc) when is_list(list) do
    {_list, next, acc} = do_index_list(list, pre + 1, acc)
    post = next
    {list, post + 1, [entry(list, pre, post) | acc]}
  end

  defp do_index(node, pre, acc) do
    {node, pre + 1, [entry(node, pre, pre) | acc]}
  end

  defp do_index_list(list, pre, acc) do
    {items, next, acc} =
      Enum.reduce(list, {[], pre, acc}, fn item, {items, next, acc} ->
        {item, next, acc} = do_index(item, next, acc)
        {[item | items], next, acc}
      end)

    {Enum.reverse(items), next, acc}
  end

  defp entry(node, pre, post), do: %{node: node, pre: pre, post: post, key: key(node)}

  defp key(node), do: :erlang.term_to_binary(node)
end
