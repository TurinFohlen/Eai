defmodule Eai.Tool.ResetSession do
  @behaviour Eai.Tool

  @impl true
  def schema do
    %{
      type: "function",
      function: %{
        name: "reset_session",
        description: """
        Force-kill a stuck or unresponsive PTY session.
        Always call list_pty_sessions first to identify the correct pty_session_id.
        After reset, the next execute_script will automatically create a fresh session.
        """,
        parameters: %{
          type: "object",
          properties: %{
            pty_session_id: %{type: "string", description: "PTY session ID to reset."}
          },
          required: ["pty_session_id"]
        }
      }
    }
  end

  @impl true
  def execute(args, pty_session_id, _chat_session_id) do
    target = Map.get(args, "pty_session_id", pty_session_id)
    Eai.Naming.pool().force_reset(target)

    %{
      status: "ok",
      message: "Session #{target} killed. Next execute_script creates fresh session."
    }
    |> Eai.Utils.sanitize_value()
    |> Jason.encode!()
  end
end
