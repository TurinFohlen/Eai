defmodule Eai.Tool.GetSubagentResult do
  @behaviour Eai.Tool

  @impl true
  def schema do
    %{
      type: "function",
      function: %{
        name: "get_subagent_result",
        description: """
        Poll for the result of a sub-agent dispatched via call_subagent.
        Returns running/completed/error status. Wait ≥5 s after call_subagent
        before first poll. Keep calling until status == "complete".

        **Token economics:** Every call to this tool is a FULL LLM API roundtrip —
        the entire conversation context is re-sent to the model each time. A 50k-token
        context polled 60 times = 3 million tokens = real money. Minimize unnecessary polls.

        **Cooldown tuning (set_config poll_cooldown_ms):**
        - Short sub-agents (quick research):  500 ms    — poll fast
        - Normal sub-agents (analysis):       2000 ms   — default, balanced
        - Heavy sub-agents (large codebase):  10000 ms  — poll sparingly
        - Long sub-agents (multi-step):       30000 ms  — heartbeat subscription

        Poll history dedup: only the two most recent "running" polls are preserved
        in the conversation history. Older running results are automatically pruned
        to keep context lean. Same mechanism as get_task_result.
        """,
        parameters: %{
          type: "object",
          properties: %{
            subagent_task_id: %{
              type: "string",
              description: "subagent_task_id returned by call_subagent."
            }
          },
          required: ["subagent_task_id"]
        }
      }
    }
  end

  @impl true
  def execute(args, _pty_session_id, _chat_session_id) do
    Process.sleep(Application.get_env(:eai, :poll_cooldown_ms))

    case args["subagent_task_id"] do
      nil ->
        Jason.encode!(%{error: "missing subagent_task_id"})

      subagent_task_id ->
        case Eai.Naming.cache().get("subagent_result:#{subagent_task_id}") do
          nil ->
            Jason.encode!(%{error: "task_not_found"})

          %{status: status, started_at: started_at} when status not in ["complete", "error"] ->
            elapsed = System.monotonic_time(:millisecond) - started_at

            Jason.encode!(%{
              status: "running",
              elapsed_ms: elapsed,
              suggested_poll_ms: Application.get_env(:eai, :poll_cooldown_ms)
            })

          result ->
            result |> Eai.Utils.sanitize_value() |> Jason.encode!()
        end
    end
  end
end
