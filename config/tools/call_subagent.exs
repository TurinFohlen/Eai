defmodule Eai.Tool.CallSubagent do
  @behaviour Eai.Tool

  @impl true
  def schema do
    %{type: "function", function: %{
      name: "call_subagent",
      description: """
      Dispatch a sub-task to an independent AI agent. Returns a subagent_task_id immediately (async).
      Use get_subagent_result to poll for the answer. Do not use recursively.
      """,
      parameters: %{type: "object",
        properties: %{
          message:        %{type: "string", description: "The task or question for the sub-agent."},
          pty_session_id: %{type: "string", description: "Optional PTY session ID for the sub-agent. Defaults to a unique ID."}
        },
        required: ["message"]
      }
    }}
  end

  @impl true
  def execute(args, _pty_session_id, _chat_session_id) do
    message          = Map.get(args, "message", "")
    pty_session_id   = Map.get(args, "pty_session_id", "subagent_#{System.unique_integer([:positive])}")
    subagent_task_id = "satask_#{System.unique_integer([:positive, :monotonic])}"

    Eai.Naming.cache().put("subagent_result:#{subagent_task_id}", %{
      status: "running",
      started_at: System.monotonic_time(:millisecond)
    })

    Task.start(fn ->
      result_entry =
        try do
          case Eai.Naming.chat().send(message, pty_session_id: pty_session_id, chat_session_id: "default") do
            {:ok, response}  -> %{status: "complete", answer: response, pty_session_id: pty_session_id}
            {:error, reason} -> %{status: "error", reason: inspect(reason), pty_session_id: pty_session_id}
          end
        rescue
          e -> %{status: "error", reason: Exception.message(e), pty_session_id: pty_session_id}
        end
      Eai.Naming.cache().put("subagent_result:#{subagent_task_id}", result_entry)
    end)

    %{subagent_task_id: subagent_task_id, status: "queued", pty_session_id: pty_session_id}
    |> Eai.Utils.sanitize_value()
    |> Jason.encode!()
  end
end
