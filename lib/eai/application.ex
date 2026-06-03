defmodule Eai.Application do
  @moduledoc false

  use Application

  def start(_type, _args) do
    attach_telemetry()

    children =
      if Application.get_env(:eai, :start_application, true) do
        IO.puts("ℹ️  EAI started.\n")
        IO.puts("ℹ️  Type Eai.help() for full documentation.\n")

        [
          {Phoenix.PubSub, name: Eai.Naming.pubsub()},
          Eai.Cache.Cache,
          Eai.Sandbox.PTYPool,
          {Eai.Chat, []}
        ]
      else
        []
      end

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
