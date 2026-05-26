defmodule Eai.Application do
  use Application

  def start(_type, _args) do
    attach_telemetry()

    children = [
      {Phoenix.PubSub, name: Eai.PubSub},
      Eai.Cache.Cache,
      Eai.Sandbox.PTYPool
    ]

    opts = [strategy: :one_for_one, name: Eai.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp attach_telemetry do
    events = Enum.map(Application.get_env(:eai, :telemetry_events, []), fn {e, _} -> e end)
    
    # 使用 & 引用具名函数，BEAM 虚拟机从此闭嘴，性能也达到最优
    :telemetry.attach_many(
      "eai-unified-handler",
      events,
      &Eai.TelemetryHandler.handle_event/4,
      nil
    )
  end
end

