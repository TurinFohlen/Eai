defmodule Eai.Tool.ExecuteScript do
  @behaviour Eai.Tool
  require Logger

  @impl true
  def schema do
    %{
      type: "function",
      function: %{
        name: "execute_script",
        description: """
        Execute a bash script inside a persistent PTY session.

        **Two modes:**

        **ACC (Asynchronous Concurrent Call) — default, `sbc: false`:**
        Returns a `task_id` immediately. You must poll with `get_task_result(task_id)`
        until status == "complete". Best for: long tasks, fire-and-forget, or when
        you want to dispatch multiple tasks in parallel across different terminals.

        **SBC (Synchronous Blocking Call) — `sbc: true`:**
        The tool internally waits for the script to finish and returns the output
        directly. No `get_task_result` call needed. **Saves 2 LLM roundtrips.**
        Best for: short tasks where you need the result NOW (echo, pwd, date,
        quick git operations). The internal polling uses `poll_cooldown_ms`.
        DO NOT use SBC for tasks that might hang or take >30 seconds — the tool
        will block your next response.

        **Decision flowchart:**
        - Need result immediately + task is fast → `sbc: true`
        - Task might take minutes or hang → `sbc: false` (ACC), use heartbeat subscription
        - Dispatching multiple independent tasks → `sbc: false`, batch poll later
        - Unsure → `sbc: true` for anything under 10 seconds; `sbc: false` otherwise

        **Parallel terminals:** Different `pty_session_id` values = independent shells.
        ACC tasks in different terminals run simultaneously.
        """,
        parameters: %{
          type: "object",
          properties: %{
            script: %{type: "string", description: "Bash script content to execute."},
            pty_session_id: %{type: "string", description: "PTY session ID (default: 'default')."},
            sbc: %{
              type: "boolean",
              description: "Synchronous Blocking Call. If true, waits for completion and returns output directly (saves 2 roundtrips). Default: false (ACC mode). Only use for tasks expected to finish quickly (<30s)."
            }
          },
          required: ["script"]
        }
      }
    }
  end

  @impl true
  def execute(args, pty_session_id, _chat_session_id) do
    sid = Map.get(args, "pty_session_id", pty_session_id)
    script = Map.get(args, "script", "")
    sbc_raw = Map.get(args, "sbc", false)
    sbc = sbc_raw == true or sbc_raw == "true"
    task_id = "task_#{System.unique_integer([:positive, :monotonic])}"
    prefix = Application.fetch_env!(:eai, :sandbox) |> Keyword.fetch!(:script_tmp_prefix)
    path = "#{prefix}#{task_id}.sh"

    with :ok <- File.write(path, script),
         :ok <- debug_script(path, script),
         {:ok, ^task_id} <-
           Eai.Naming.pool().exec_async(sid, "bash #{path}; rm -f #{path}", task_id) do

      if sbc do
        sbc_wait(task_id, sid)
      else
        %{task_id: task_id, status: "queued"}
        |> Eai.Utils.sanitize_value()
        |> Jason.encode!()
      end
    else
      err ->
        %{error: inspect(err)}
        |> Eai.Utils.sanitize_value()
        |> Jason.encode!()
    end
  end

  # ── SBC: internal polling loop ──────────────────────────────────

  defp sbc_wait(task_id, pty_session_id, max_loops \\ 60) do
    cooldown = Application.get_env(:eai, :poll_cooldown_ms) || 2000
    Process.sleep(cooldown)

    # Check interrupt flag
    if Eai.Task.check_and_clear_interrupt_flag(pty_session_id) do
      Eai.Naming.pool().interrupt_task(pty_session_id)
      %{status: "interrupted", task_id: task_id}
      |> Eai.Utils.sanitize_value()
      |> Jason.encode!()
    else
      case Eai.Task.get(task_id) do
        %{status: "complete", output: output} ->
          %{status: "complete", output: output, task_id: task_id}
          |> Eai.Utils.sanitize_value()
          |> Jason.encode!()

        nil ->
          %{error: "task not found", task_id: task_id}
          |> Jason.encode!()

        _ when max_loops <= 0 ->
          Logger.warning("SBC timeout for #{task_id}, force-completing")
          case Eai.Task.force_complete(task_id) do
            {:ok, output} ->
              Eai.Naming.pool().clear_task(pty_session_id, task_id)
              %{status: "timeout", output: output, task_id: task_id}
              |> Eai.Utils.sanitize_value()
              |> Jason.encode!()
            _ ->
              %{error: "SBC timeout — task never completed", task_id: task_id}
              |> Jason.encode!()
          end

        _ ->
          sbc_wait(task_id, pty_session_id, max_loops - 1)
      end
    end
  end

  defp debug_script(path, script) do
    if Application.fetch_env!(:eai, :sandbox) |> Keyword.fetch!(:debug_pty_output) do
      IO.puts("\n=== SCRIPT START [#{path}] ===\n#{script}\n=== SCRIPT END ===")
    end

    :ok
  end
end