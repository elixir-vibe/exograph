defmodule Exograph.Web.Health do
  @moduledoc """
  Builds the public health payload for Exograph's web API.

  The payload is intentionally deployment-focused: it identifies the running
  application release, the opened index shape, and runtime metadata needed to
  confirm which artifact and shard set are live.
  """

  alias Exograph.{DuckDBShards, ShardedIndex}

  @doc """
  Returns JSON-encodable health metadata for the running web index.
  """
  def payload(index) do
    %{
      status: status(index),
      application: %{
        name: "exograph",
        version: app_version(),
        release: release_name(),
        release_path: release_path()
      },
      index: index_health(index),
      runtime: %{
        public_url: Application.get_env(:exograph, :web_public_url),
        site_name: Application.get_env(:exograph, :web_site_name),
        prefix: Application.get_env(:exograph, :web_prefix),
        node: Atom.to_string(node()),
        otp_release: System.otp_release(),
        elixir_version: System.version()
      }
    }
  end

  defp status(nil), do: "unavailable"
  defp status(_index), do: "ok"

  defp app_version do
    :exograph
    |> Application.spec(:vsn)
    |> to_string()
  end

  defp release_name do
    case release_path() do
      nil -> nil
      path -> Path.basename(path)
    end
  end

  defp release_path do
    System.get_env("RELEASE_ROOT") ||
      case File.cwd() do
        {:ok, cwd} -> Path.expand(cwd)
        {:error, _reason} -> nil
      end
  end

  defp index_health(%ShardedIndex{shards: shards, manifest: %DuckDBShards.Manifest{} = manifest}) do
    %{
      kind: "sharded_duckdb",
      prefix: manifest.prefix,
      shard_count: manifest.shard_count,
      opened_shards: length(shards),
      packages: shard_package_count(manifest),
      databases: Enum.map(manifest.shards, &shard_database/1)
    }
  end

  defp index_health(%ShardedIndex{shards: shards, manifest: manifest}) do
    shard_count = length(shards)

    %{
      kind: "sharded_duckdb",
      shard_count: shard_count,
      opened_shards: shard_count,
      manifest: inspect(manifest)
    }
  end

  defp index_health(%{inverted: %{prefix: prefix}}) do
    %{
      kind: "duckdb",
      prefix: prefix,
      shard_count: 1,
      opened_shards: 1
    }
  end

  defp index_health(nil), do: %{kind: nil, shard_count: 0, opened_shards: 0}
  defp index_health(_index), do: %{kind: "unknown", shard_count: nil, opened_shards: nil}

  defp shard_package_count(%DuckDBShards.Manifest{shards: shards}) do
    shards
    |> Enum.flat_map(& &1.packages)
    |> Enum.uniq()
    |> length()
  end

  defp shard_database(%DuckDBShards.Shard{id: id, prefix: prefix, database: database}) do
    %{id: id, prefix: prefix, database: database}
  end
end
