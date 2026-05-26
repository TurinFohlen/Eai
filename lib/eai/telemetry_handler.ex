defmodule Eai.TelemetryHandler do
  require Logger

  # 将标签映射存在模块属性中
  @labels Enum.into(Application.compile_env(:eai, :telemetry_events, []), %{})

  def handle_event(event, measurements, metadata, _config) do
    label = Map.get(@labels, event, "Unknown Event")
    Logger.info("[TELE] #{label} | #{format_measurements(measurements)} | #{format_metadata(metadata)}")
  end

  defp format_measurements(m) do
    m
    |> Enum.reject(fn {k, _} -> k == :system_time end)
    |> Enum.map_join(" ", fn {k, v} -> "#{k}=#{v}" end)
  end

  defp format_metadata(m) do
    m |> Enum.map_join(" ", fn {k, v} -> "#{k}=#{inspect(v)}" end)
  end
end

