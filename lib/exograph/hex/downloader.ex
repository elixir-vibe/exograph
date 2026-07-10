defmodule Exograph.Hex.Downloader do
  @moduledoc false

  @default_mirrors ["https://repo.hex.pm"]

  def fetch(name, version, opts \\ []) do
    mirrors = Keyword.get(opts, :mirrors, @default_mirrors)
    strategy = Keyword.get(opts, :mirror_strategy, :round_robin)
    index = Keyword.get(opts, :index, 0)
    timeout = Keyword.get(opts, :timeout, 120_000)
    cache_dir = Keyword.get(opts, :cache_dir)
    tarball_dir = Keyword.get(opts, :tarball_dir)

    slug = "#{name}-#{version}"
    cached = if cache_dir, do: Path.join(cache_dir, "#{slug}.tar")

    tarball_bytes =
      cond do
        tarball_dir ->
          tarball_dir |> Path.join("#{slug}.tar") |> File.read!()

        cached && File.exists?(cached) ->
          File.read!(cached)

        true ->
          bytes = download!(name, version, ordered_mirrors(mirrors, strategy, index), timeout)
          if cached, do: write_cached!(cached, bytes)
          bytes
      end

    extract_to_memory(tarball_bytes)
  end

  defp download!(name, version, mirrors, timeout) do
    path = "/tarballs/#{name}-#{version}.tar"

    {result, failures} =
      Enum.reduce_while(mirrors, {nil, []}, fn mirror, {_body, failures} ->
        url = IO.iodata_to_binary([mirror, path])

        case download_url(url, timeout) do
          {:ok, body} -> {:halt, {body, failures}}
          {:error, reason} -> {:cont, {nil, [{url, reason} | failures]}}
        end
      end)

    result || raise download_error(name, version, failures)
  end

  defp download_url(url, timeout) do
    case Req.get(url, receive_timeout: timeout, retry: false, decode_body: false) do
      {:ok, %{status: status, body: body}} when status in 200..299 -> {:ok, body}
      {:ok, %{status: status}} -> {:error, {:http_status, status}}
      {:error, reason} -> {:error, reason}
    end
  rescue
    error in [ArgumentError, RuntimeError] -> {:error, error}
  end

  defp download_error(name, version, failures) do
    details =
      failures
      |> Enum.reverse()
      |> Enum.map_join("; ", fn {url, reason} -> "#{url}: #{inspect(reason, limit: 10)}" end)

    "failed to download #{name}-#{version} from all mirrors (#{details})"
  end

  def extract_to_memory(tarball_bytes) do
    case :hex_tarball.unpack(tarball_bytes, :memory) do
      {:ok, %{contents: contents}} ->
        Enum.map(contents, fn {path, content} ->
          {to_string(path), content}
        end)

      {:error, reason} ->
        raise "hex_tarball.unpack failed: #{inspect(reason)}"
    end
  end

  defp write_cached!(path, bytes) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, bytes)
  end

  defp ordered_mirrors(mirrors, :random, _index) do
    Enum.shuffle(mirrors)
  end

  defp ordered_mirrors(mirrors, _round_robin, index) do
    {tail, head} = Enum.split(mirrors, rem(index, length(mirrors)))
    head ++ tail
  end
end
