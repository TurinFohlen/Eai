defmodule Eai.Hook.SessionLog do
  @moduledoc """
  Observability hook: fires telemetry for every tool call and LLM request.

  Covers all four event types (:pre, :post, :llm_pre, :llm_post).
  Does not block or modify — pure observation.
  """

  use Eai.Hook, priority: 20

  @impl true
  def interest(_event, _tool_name, _payload), do: true

  @impl true
  def verdict(event, tool_name, %{args: args}) when event in [:pre, :llm_pre] do
    :telemetry.execute(
      [:eai, :hook, :session_log, event],
      %{system_time: System.system_time()},
      %{tool: tool_name, args_count: length(List.wrap(args))}
    )
    :ok
  end

  @impl true
  def verdict(event, tool_name, _payload, result) when event in [:post, :llm_post] do
    result_bytes =
      case result do
        s when is_binary(s) -> byte_size(s)
        l when is_list(l) -> length(l)
        _ -> 1
      end

    :telemetry.execute(
      [:eai, :hook, :session_log, event],
      %{system_time: System.system_time()},
      %{tool: tool_name, result_bytes: result_bytes}
    )
    :ok
  end
end