defmodule Eai.Hook.SessionLog do
  @moduledoc """
  Observability hook: fires telemetry events for every tool call.

  Attaches to all (pre + post) events on all tools. Does not block or modify.
  Useful for audit logs, metrics dashboards, and debugging.

  ## Telemetry events emitted

  - `[:eai, :hook, :session_log, :pre]`
    measurements: `%{system_time: integer}`
    metadata: `%{tool: tool_name, args_length: integer}`

  - `[:eai, :hook, :session_log, :post]`
    measurements: `%{system_time: integer}`
    metadata: `%{tool: tool_name, result_size: integer}`

  ## How to attach a handler

      :telemetry.attach(
        "my-session-log",
        [:eai, :hook, :session_log, :pre],
        fn event, measurements, metadata, _config ->
          IO.inspect({event, measurements, metadata})
        end,
        nil
      )
  """

  use Eai.Hook, priority: 20

  @impl true
  @doc "Observe all tools, both pre and post."
  def interest(_event, _tool_name, _payload), do: true

  @impl true
  def verdict(:pre, tool_name, %{args: args}) do
    # Pure observation — fire telemetry and pass through.
    # No Task.await needed here since we're only writing to telemetry
    # (synchronous, in-process, microseconds).
    :telemetry.execute(
      [:eai, :hook, :session_log, :pre],
      %{system_time: System.system_time()},
      %{tool: tool_name, args_length: length(List.wrap(args))}
    )

    :ok
  end

  @impl true
  def verdict(:post, tool_name, _payload, result) do
    result_size =
      case result do
        s when is_binary(s) -> byte_size(s)
        l when is_list(l) -> length(l)
        _ -> 1
      end

    :telemetry.execute(
      [:eai, :hook, :session_log, :post],
      %{system_time: System.system_time()},
      %{tool: tool_name, result_size: result_size}
    )

    :ok
  end
end
