defmodule Eai.Tool.GetSubagentResult do
  @behaviour Eai.Tool

  @impl true
  def schema do
    %{type: "function", function: %{
      name: "get_subagent_result",
      description: """
      Retrieve the result of a previously dispatched sub-agent task by subagent_task_id.
      Poll until status == "complete". Wait at least 5 s after call_subagent before first poll.
      """,
      parameters: %{type: "object",
        properties: %{subagent_task_id: %{type: "string", description: "subagent_task_id returned by call_subagent."}},
        required: ["subagent_task_id"]
      }
    }}
  end

  @impl true
  def execute(args, _pty_session_id, _chat_session_id) do
    Process.sleep(Application.get_env(:eai, :poll_cooldown_ms))
    case args["subagent_task_id"] do
      nil -> Jason.encode!(%{error: "missing subagent_task_id"})
      subagent_task_id ->
        case Eai.Naming.cache().get("subagent_result:#{subagent_task_id}") do
          nil -> Jason.encode!(%{error: "task_not_found"})
          %{status: status, started_at: started_at} when status not in ["complete", "error"] ->
            elapsed = System.monotonic_time(:millisecond) - started_at
            Jason.encode!(%{status: "running", time: elapsed})
          result -> result |> Eai.Utils.sanitize_value() |> Jason.encode!()
        end
    end
  end
end
