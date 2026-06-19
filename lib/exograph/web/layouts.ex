defmodule Exograph.Web.Layouts do
  @moduledoc false
  use Exograph.Web, :html

  alias Exograph.Web.Metadata

  embed_templates("layouts/*")
end
