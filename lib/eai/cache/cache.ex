defmodule Eai.Cache.Cache do
  @moduledoc "Nebulex cache adapter for EAI"

  use Nebulex.Cache,
    otp_app: :eai,
    adapter: Nebulex.Adapters.Local
end
