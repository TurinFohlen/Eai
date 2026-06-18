defmodule Eai.Hook.SessionLog do
  @moduledoc """
  Observability hook: fires telemetry for every tool call and LLM request.

  Covers all four event types (:pre, :post, :llm_pre, :llm_post).
  Does not block or modify — pure observation.
  """

  use Eai.Hook, priority: 20

  @impl true
  def interest(_event, _tool_name, _payload), do: true

  # Tool pre-hooks: payload shape is %{mod, fun, args: [...]}.
  @impl true
  def verdict(:pre, tool_name, payload) do
    args = Map.get(payload, :args, [])

    args_count =
      args
      |> List.wrap()
      |> length()

    :telemetry.execute(
      [:eai, :hook, :session_log, :pre],
      %{system_time: System.system_time()},
      %{tool: tool_name, args_count: args_count}
    )

    :ok
  end

  # LLM pre-hooks: payload shape is %{messages, pty_session_id, chat_session_id, opts}.
  # There's no :args key here — that's what caused the original
  # FunctionClauseError. We log a message count + a flag instead.
  @impl true
  def verdict(:llm_pre, tool_name, payload) do
    messages = Map.get(payload, :messages, [])
    opts = Map.get(payload, :opts, %{})
    has_tools? = match?(%{tools: tools} when is_list(tools) and tools != [], opts)

    :telemetry.execute(
      [:eai, :hook, :session_log, :llm_pre],
      %{system_time: System.system_time()},
      %{tool: tool_name, message_count: length(List.wrap(messages)), has_tools: has_tools?}
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
