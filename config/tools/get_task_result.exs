defmodule Eai.Tool.GetTaskResult do
  @behaviour Eai.Tool

  @impl true
  def schema do
    %{
      type: "function",
      function: %{
        name: "get_task_result",
        description: """
        Poll for output of a script submitted via execute_script.
        Returns running/completed/not_found status. Wait ≥5 s after execute_script
        before first poll. Keep calling until status == "complete".

        **Token economics:** Every call to this tool is a FULL LLM API roundtrip —
        the entire conversation context is re-sent to the model each time. A 50k-token
        context polled 60 times = 3 million tokens = real money. Minimize unnecessary polls.

        **Cooldown tuning (set_config poll_cooldown_ms):**
        - Trivial tasks (echo, pwd, date):   500 ms   — poll fast
        - Normal tasks (compile, git, grep): 2000 ms  — default, balanced
        - Heavy tasks (deps.get, large ops): 10000 ms — poll sparingly
        - Long tasks (docker, pip install):  30000-60000 ms — heartbeat subscription

        **Heartbeat Subscription pattern:** For a 60-second task, do NOT poll every
        2 seconds (30 roundtrips). Instead set poll_cooldown_ms=30000 and poll 2-3
        times total. Same result, 10× cheaper in token cost.

        **Adaptive tuning:** Raise cooldown before heavy tasks, lower it after.
        Use set_config freely — changes take effect immediately, node-wide.
        """,
        parameters: %{
          type: "object",
          properties: %{
            task_id: %{type: "string", description: "task_id returned by execute_script."}
          },
          required: ["task_id"]
        }
      }
    }
  end

  @impl true
  def execute(args, pty_session_id, _chat_session_id) do
    Process.sleep(Application.get_env(:eai, :poll_cooldown_ms))

    case args["task_id"] do
      nil ->
        Jason.encode!(%{error: "missing task_id"})

      task_id ->
        if Eai.ResultCollector.check_and_clear_interrupt_flag(pty_session_id) do
          Eai.PTY.interrupt_task(pty_session_id)

          %{status: "complete", output: "Task forcefully interrupted by user. Please reply now."}
          |> Eai.Utils.sanitize_value()
          |> Jason.encode!()
        else
          case Eai.ResultCollector.check_timeout_window(pty_session_id) do
            msg when is_binary(msg) ->
              %{status: "complete", output: msg} |> Eai.Utils.sanitize_value() |> Jason.encode!()

            _ ->
              result =
                case Eai.ResultCollector.get(task_id) do
                  %{status: "complete", output: output} ->
                    %{status: "complete", output: output}

                  %{started_at: started_at} when not is_nil(started_at) ->
                    %{
                      status: "running",
                      elapsed_ms: System.monotonic_time(:millisecond) - started_at,
                      suggested_poll_ms: Application.get_env(:eai, :poll_cooldown_ms)
                    }

                  %{} ->
                    %{status: "running", time: 0}

                  nil ->
                    %{status: "not_found"}
                end

              result |> Eai.Utils.sanitize_value() |> Jason.encode!()
          end
        end
    end
  end
end
