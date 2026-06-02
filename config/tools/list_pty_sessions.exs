defmodule Eai.Tool.ListPtySessions do
  @behaviour Eai.Tool

  @impl true
  def schema do
    %{type: "function", function: %{
      name: "list_pty_sessions",
      description: "List all active PTY sessions with their status and current task.",
      parameters: %{type: "object", properties: %{}, required: []}
    }}
  end

  @impl true
  def execute(_args, _pty_session_id, _chat_session_id) do
    Eai.Naming.pool().list_sessions()
    |> Eai.Utils.sanitize_value()
    |> Jason.encode!()
  end
end
