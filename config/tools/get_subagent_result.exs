defmodule Eai.Tool.GetSubagentResult do
  @moduledoc """
  Step 2 distinguishes three in-flight subagent statuses for an LLM caller:

  * `pending` — the subagent was enqueued (the target chat_session was busy
    at dispatch time) and is waiting for a free slot. `time` is milliseconds
    since `queued_at`.
  * `running` — the subagent is actively executing. `time` is milliseconds
    since `started_at`.
  * `complete` / `error` — terminal. Returned as-is.

  Additionally, an entry older than `:eai, :subagent_stale_after_ms` (default
  24h) is reported as `status: "error", reason: "stale"` even if its raw
  cache status is still `pending` or `running`. This guards against a queue
  that was orphaned (e.g. node crash mid-dispatch) leaving an LLM polling
  forever.
  """

  @behaviour Eai.Tool

  @impl true
  def schema do
    %{
      type: "function",
      function: %{
        name: "get_subagent_result",
        description: """
        Poll for the result of a sub-agent dispatched via call_subagent.
        Returns one of:
          - `pending`  — subagent is queued (chat_session was busy); will
                         dispatch automatically when the running task ends.
          - `running`  — subagent is actively executing.
          - `complete` — final answer ready in `answer`.
          - `error`    — final error in `reason`.
        Wait ≥5 s after call_subagent before first poll. Keep calling until
        status == "complete" or "error". A `pending` status may last minutes
        if the chat_session has a long-running task; do not give up early.

        **Token economics:** Every call to this tool is a FULL LLM API roundtrip —
        the entire conversation context is re-sent to the model each time. A 50k-token
        context polled 60 times = 3 million tokens = real money. Minimize unnecessary polls.

        **Cooldown tuning (set_config poll_cooldown_ms):**
        - Short sub-agents (quick research):  500 ms    — poll fast
        - Normal sub-agents (analysis):       2000 ms   — default, balanced
        - Heavy sub-agents (large codebase):  10000 ms  — poll sparingly
        - Long sub-agents (multi-step):       30000 ms  — heartbeat subscription

        Poll history dedup: only the two most recent "pending" / "running" polls are preserved
        in the conversation history. Older results are automatically pruned
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
        result_key = "subagent_result:#{subagent_task_id}"
        now = System.monotonic_time(:millisecond)

        case Eai.Naming.cache().get(result_key) do
          nil ->
            Jason.encode!(%{error: "task_not_found"})

          # Pending: subagent was enqueued (chat session was busy). Time
          # since `queued_at`. Falls through to the stale check below.
          %{status: "pending", queued_at: queued_at} = entry ->
            elapsed = now - queued_at

            if elapsed > stale_after_ms() do
              # Mark the entry as error so the LLM doesn't keep polling
              # forever. This is a defensive write — it only fires if the
              # queue has been orphaned (e.g. node crash before dequeue).
              Eai.Naming.cache().put(result_key, %{entry | status: "error", reason: "stale"})

              Jason.encode!(%{status: "error", reason: "stale"})
            else
              Jason.encode!(%{
                status: "pending",
                time: elapsed,
                suggested_poll_ms: Application.get_env(:eai, :poll_cooldown_ms)
              })
            end

          # Running: subagent is actively executing. Time since `started_at`.
          # Same stale check as the pending branch.
          %{status: "running", started_at: started_at} = entry ->
            elapsed = now - started_at

            if elapsed > stale_after_ms() do
              Eai.Naming.cache().put(result_key, %{entry | status: "error", reason: "stale"})

              Jason.encode!(%{status: "error", reason: "stale"})
            else
              Jason.encode!(%{
                status: "running",
                time: elapsed,
                suggested_poll_ms: Application.get_env(:eai, :poll_cooldown_ms)
              })
            end

          # Complete / error: terminal states, returned verbatim. Do not
          # rename any keys here — LLMs may inspect `answer` / `reason`
          # directly.
          result ->
            result |> Eai.Utils.sanitize_value() |> Jason.encode!()
        end
    end
  end

  # Default 24h. Override via `config :eai, :subagent_stale_after_ms, ms`.
  # If the entry is older, get_subagent_result auto-converts it to
  # status: "error", reason: "stale" so an LLM never polls a dead task
  # forever.
  defp stale_after_ms do
    Application.get_env(:eai, :subagent_stale_after_ms, :timer.hours(24))
  end
end
