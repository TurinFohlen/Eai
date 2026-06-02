defmodule Eai.Tool.Helpers do
  @moduledoc "Shared utilities used by two or more tool implementations."

  def sandbox_cfg(key), do: Application.fetch_env!(:eai, :sandbox) |> Keyword.fetch!(key)
  def poll_cooldown_ms, do: Application.get_env(:eai, :poll_cooldown_ms)
end
