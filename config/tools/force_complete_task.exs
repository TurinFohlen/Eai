defmodule Eai.Tool.ForceCompleteTask do
  @behaviour Eai.Tool

  @impl true
  def schema do
    %{
      type: "function",
      function: %{
        name: "force_complete_task",
        description: """
        Force-collect output from a running/stuck task and mark it complete.
        Use when a task hangs but has produced partial output you want to recover.
        Always call list_pty_sessions first to confirm the task_id exists.

        This is a last-resort tool — prefer adjusting poll_cooldown_ms via set_config
        and waiting patiently. force_complete extracts whatever is in the buffer;
        the output may be incomplete.
        """,
        parameters: %{
          type: "object",
          properties: %{
            task_id: %{type: "string", description: "The task_id to force-complete."},
            pty_session_id: %{
              type: "string",
              description: "PTY session ID (default: current session)."
            }
          },
          required: ["task_id"]
        }
      }
    }
  end

  @impl true
  def execute(args, pty_session_id, _chat_session_id) do
    task_id = Map.get(args, "task_id", "")
    target = Map.get(args, "pty_session_id", pty_session_id)

    {:ok, output} = Eai.ResultCollector.force_complete(task_id)
    Eai.PTY.clear_task(target, task_id)
    %{status: "complete", output: output} |> Eai.Utils.sanitize_value() |> Jason.encode!()
  end
end
