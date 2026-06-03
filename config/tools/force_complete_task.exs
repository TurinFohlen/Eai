defmodule Eai.Tool.ForceCompleteTask do
  @behaviour Eai.Tool

  @impl true
  def schema do
    %{
      type: "function",
      function: %{
        name: "force_complete_task",
        description: """
        Force-collect the current output of a running task and mark it as complete.
        Use when a task appears stuck but has produced output you want to retrieve.
        Always call list_pty_sessions first to confirm the task_id.
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

    case Eai.ResultCollector.force_complete(task_id) do
      {:ok, output} ->
        Eai.Naming.pool().clear_task(target, task_id)
        %{status: "complete", output: output} |> Eai.Utils.sanitize_value() |> Jason.encode!()

      _ ->
        Jason.encode!(%{error: "force_complete failed or task not found"})
    end
  end
end
