defmodule Exograph.Web.RateLimiter do
  @moduledoc false

  if Code.ensure_loaded?(Hammer) do
    Code.eval_quoted(
      quote do
        use Hammer, backend: :ets
      end,
      [],
      __ENV__
    )
  else
    def start_link(_opts), do: :ignore
    def hit(_key, _scale, _limit), do: {:allow, 0}
  end
end
