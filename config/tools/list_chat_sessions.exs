defmodule Eai.Tool.ListChatSessions do
  @behaviour Eai.Tool

  @impl true
  def schema do
    %{
      type: "function",
      function: %{
        name: "list_chat_sessions",
        description:
          "List all active chat sessions with their message count and status (idle/busy).",
        parameters: %{type: "object", properties: %{}, required: []}
      }
    }
  end

  @impl true
  def execute(_args, _pty_session_id, _chat_session_id) do
    Eai.Naming.chat().list_chat_sessions()
    |> Eai.Utils.sanitize_value()
    |> Jason.encode!()
  end
end
