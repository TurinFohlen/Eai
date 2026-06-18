defmodule Eai.TelemetryHandler do
  @moduledoc """
  统一 telemetry 事件处理器。

  所有事件以结构化 map 记录，key 固定为：
    event / label / measurements / metadata / ts

  Logger.metadata 会被 Logger 后端自动附加，JSON formatter
  （如 logger_json）可直接接入 ELK / Loki / Datadog。
  """
  require Logger

  @labels Enum.into(Application.compile_env(:eai, :telemetry_events, []), %{})

  def handle_event(event, measurements, metadata, _config) do
    label = Map.get(@labels, event, inspect(event))

    # 去掉高精度系统时间（不可序列化），保留业务字段
    measurements = Map.delete(measurements, :system_time)

    Logger.info("telemetry",
      event: event,
      label: label,
      measurements: measurements,
      metadata: metadata
    )
  end
end
