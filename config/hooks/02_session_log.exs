defmodule Eai.Hook.SessionLog do
  @moduledoc """
  Observability hook: fires telemetry events for every tool call.

  Attaches to all (pre + post) events on all tools. Does not block or modify.

  ## Telemetry events

  - `[:eai, :hook, :session_log, :pre]`
    measurements: `%{system_time: integer}`
    metadata: `%{tool: String.t(), args_count: integer}`

  - `[:eai, :hook, :session_log, :post]`
    measurements: `%{system_time: integer}`
    metadata: `%{tool: String.t(), result_bytes: integer}`
  """

  use Eai.Hook, priority: 20

  @impl true
  def interest(_event, _tool_name, _payload), do: true

  @impl true
  def verdict(:pre, tool_name, %{args: args}) do
    :telemetry.execute(
      [:eai, :hook, :session_log, :pre],
      %{system_time: System.system_time()},
      %{tool: tool_name, args_count: length(List.wrap(args))}
    )
    :ok
  end

  @impl true
  def verdict(:post, tool_name, _payload, result) do
    result_bytes =
      case result do
        s when is_binary(s) -> byte_size(s)
        l when is_list(l) -> length(l)
        _ -> 1
      end

    :telemetry.execute(
      [:eai, :hook, :session_log, :post],
      %{system_time: System.system_time()},
      %{tool: tool_name, result_bytes: result_bytes}
    )
    :ok
  end
end
