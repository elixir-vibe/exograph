defmodule Exograph.Hex.Registry do
  @moduledoc false

  @repo_url "https://repo.hex.pm"
  @api_url "https://hex.pm/api/packages"

  def versions(opts \\ []) do
    registry_url = Keyword.get(opts, :registry_url) || @repo_url
    config = hex_config(registry_url)

    case :hex_repo.get_versions(config) do
      {:ok, {200, _headers, %{packages: packages}}} ->
        packages

      {:ok, {status, _headers, body}} ->
        raise "GET #{registry_url}/versions failed with #{status}: #{inspect(body)}"

      {:error, reason} ->
        raise "GET #{registry_url}/versions failed: #{inspect(reason)}"
    end
  end

  def latest(opts \\ []) do
    limit = Keyword.get(opts, :limit)

    versions(opts)
    |> Enum.map(fn %{name: name, versions: vers} ->
      %{name: to_string(name), version: latest_version(vers)}
    end)
    |> maybe_limit(limit)
  end

  def top(opts \\ []) do
    limit = Keyword.get(opts, :limit, 300)
    timeout = Keyword.get(opts, :timeout, 120_000)
    api_url = Keyword.get(opts, :api_url) || @api_url

    Stream.iterate(1, &(&1 + 1))
    |> Enum.reduce_while([], fn page, acc ->
      batch = get_json!("#{api_url}?sort=downloads&page=#{page}", timeout)
      next = Enum.reverse(batch, acc)

      cond do
        length(next) >= limit -> {:halt, next |> Enum.reverse() |> Enum.take(limit)}
        batch == [] -> {:halt, Enum.reverse(next)}
        true -> {:cont, next}
      end
    end)
    |> Enum.map(fn pkg ->
      %{name: pkg["name"], version: pkg["latest_stable_version"] || pkg["latest_version"]}
    end)
  end

  def all_versions(opts \\ []) do
    limit = Keyword.get(opts, :limit)

    versions(opts)
    |> Enum.flat_map(fn %{name: name, versions: vers} ->
      Enum.map(vers, &%{name: to_string(name), version: to_string(&1)})
    end)
    |> maybe_limit(limit)
  end

  defp latest_version(versions) do
    versions
    |> Enum.map(&to_string/1)
    |> Enum.max_by(fn v ->
      case Version.parse(v) do
        {:ok, parsed} -> {1, parsed}
        :error -> {0, v}
      end
    end)
  end

  defp maybe_limit(entries, nil), do: entries
  defp maybe_limit(entries, limit), do: Enum.take(entries, limit)

  defp hex_config(registry_url) do
    :hex_core.default_config()
    |> Map.put(:repo_url, registry_url)
    |> Map.put(:http_user_agent_fragment, <<"(exograph)">>)
  end

  defp get_json!(url, timeout) do
    Req.get!(url, receive_timeout: timeout).body
  end
end
