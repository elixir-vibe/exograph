defmodule Exograph.Web.Plugs.RateLimit do
  @moduledoc false
  import Plug.Conn

  @default_limit 60
  @default_scale :timer.minutes(1)

  def init(opts), do: opts

  def call(conn, opts) do
    if Code.ensure_loaded?(Hammer) do
      limit = Keyword.get(opts, :limit, @default_limit)
      scale = Keyword.get(opts, :scale, @default_scale)
      key = "api:#{client_ip(conn)}"

      case Exograph.Web.RateLimiter.hit(key, scale, limit) do
        {:allow, count} ->
          conn
          |> put_resp_header("x-ratelimit-limit", to_string(limit))
          |> put_resp_header("x-ratelimit-remaining", to_string(max(limit - count, 0)))

        {:deny, retry_after} ->
          response =
            Exograph.API.ErrorResponse.new(
              "rate_limit_exceeded",
              "Rate limit exceeded",
              %{"retry_after_ms" => retry_after}
            )

          conn
          |> put_resp_header("x-ratelimit-limit", to_string(limit))
          |> put_resp_header("x-ratelimit-remaining", "0")
          |> put_resp_header("retry-after", to_string(div(retry_after, 1000)))
          |> put_resp_content_type("application/json")
          |> send_resp(429, JSON.encode!(JSONCodec.dump(response)))
          |> halt()
      end
    else
      conn
    end
  end

  defp client_ip(conn) do
    case get_req_header(conn, "x-forwarded-for") do
      [ip | _] -> ip |> String.split(",", parts: 2) |> List.first() |> String.trim()
      [] -> conn.remote_ip |> :inet.ntoa() |> to_string()
    end
  end
end
