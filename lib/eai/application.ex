defmodule Eai.Application do
  use Application

  def start(_type, _args) do
    IO.puts("ℹ️  EAI started. Type Eai.help() for full documentation.\n")
    attach_telemetry()

    children = [
      {Phoenix.PubSub, name: Eai.PubSub},
      Eai.Cache.Cache,
      Eai.Sandbox.PTYPool,
      {Eai.Chat, []},
    ]

    opts = [strategy: :one_for_one, name: Eai.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp attach_telemetry do
    events = Enum.map(Application.get_env(:eai, :telemetry_events, []), fn {e, _} -> e end)
    :telemetry.attach_many(
      "eai-unified-handler",
      events,
      &Eai.TelemetryHandler.handle_event/4,
      nil
    )
  end
end