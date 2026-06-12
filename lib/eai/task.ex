defmodule Eai.Task do
  @moduledoc """
  Task result management — the engine behind get_task_result / force_complete_task tools.

  Manages per-task buffers (sentinel-based stream collection), interrupt flags,
  and timeout windows via the Cache. Lives at the tool layer, not in the sandbox.
  """

  alias Eai.Cache.Cache
  require Logger

  @left Application.compile_env(:eai, [:sandbox, :sentinel_left])
  @right Application.compile_env(:eai, [:sandbox, :sentinel_right])

  def sentinel_left, do: @left
  def sentinel_right, do: @right

  # ── 任务生命周期 ──────────────────────────────────────────────────

  def init_task(task_id) do
    Cache.put("result:#{task_id}", %{
      status: "collecting",
      started_at: System.monotonic_time(:millisecond)
    })
    Cache.put("result:#{task_id}:buffer", "")
  end

  @doc """
  Stream-collect PTY output, extract between sentinels.

  Called by PTYPool on_data callback. Buffers and matches sentinel patterns
  to extract clean result. Returns `:collecting` while streaming, `{:complete, output}` when done.

  Internal use (called by PTYPool).

  ## Options
    * `task_id` (string) — Task ID.
    * `data` (string) — New PTY output chunk.

  ## Returns
      `:collecting` — still waiting for sentinel-marked output
      `{:complete, output}` — result extracted, ready to use
  """
  def collect(task_id, data) do
    data = Eai.Utils.sanitize_value(data)
    buf_key = "result:#{task_id}:buffer"
    res_key = "result:#{task_id}"

    buffer = Cache.get(buf_key) || ""
    new_buf = buffer <> data

    clean_buf =
      new_buf
      |> String.replace("\r\n", "\n")
      |> String.replace("\r", "\n")
      |> String.replace(~r/\e\[[0-9;]*[a-zA-Z]/, "")

    current = Cache.get(res_key) || %{status: "collecting"}

    if current.status == "complete" do
      {:complete, current.output}
    else
      case {find_first(clean_buf, @left), find_first(clean_buf, @right)} do
        {{start_pos, start_len}, {end_pos, _end_len}} when end_pos > start_pos ->
          core_start = start_pos + start_len
          core_len = max(end_pos - core_start, 0)

          output =
            clean_buf
            |> :binary.part(core_start, core_len)
            |> String.trim()

          Cache.put(res_key, %{output: output, status: "complete"})
          Cache.delete(buf_key)
          {:complete, output}

        _ ->
          Cache.put(buf_key, clean_buf)
          :collecting
      end
    end
  end

  @doc """
  Poll task result from cache.

  Returns status and output (if complete). Used by `get_task_result` tool.

  ## Options
    * `task_id` (string) — Task ID to poll.

  ## Returns
      `%{status: "complete", output: "..."}`
      `%{status: "running" | "collecting", started_at: ...}`
      `nil` — task not found or expired

  ## Example
      iex> Eai.Task.get("task_1234567890")
      %{status: "complete", output: "total 42\\n-rw-r--r--  ..."}
  """
  def get(task_id) do
    case Cache.get("result:#{task_id}") do
      %{status: "complete"} = r -> %{output: r.output, status: "complete"}
      %{status: status} = r -> %{status: status, started_at: Map.get(r, :started_at)}
      nil -> nil
    end
  end

  @doc """
  Force task completion, extracting output from buffer (even if incomplete).

  Used by `force_complete_task` tool when task hangs or times out.
  Tries to extract content between sentinels; falls back to buffer tail.

  ## Options
    * `task_id` (string) — Task to force complete.

  ## Returns
      `{:ok, output}` — partial or complete output extracted
      `{:error, reason}` — task not found or other error

  ## Example
      iex> Eai.Task.force_complete("task_1234567890")
      {:ok, "partial output from hung task..."}
  """
  def force_complete(task_id) do
    buf_key = "result:#{task_id}:buffer"
    res_key = "result:#{task_id}"

    buffer = Cache.get(buf_key) || ""
    current = Cache.get(res_key)

    if current && current.status == "complete" do
      {:ok, current.output}
    else
      output =
        case {find_first(buffer, @left), find_first(buffer, @right)} do
          {{start_pos, start_len}, {end_pos, _}} when end_pos > start_pos ->
            core_start = start_pos + start_len
            core_len = max(end_pos - core_start, 0)
            buffer |> :binary.part(core_start, core_len) |> String.trim()

          {{start_pos, start_len}, _} ->
            buffer
            |> :binary.part(start_pos + start_len, byte_size(buffer) - start_pos - start_len)
            |> String.trim()

          _ ->
            buffer |> String.trim()
        end

      Cache.put(res_key, %{output: output, status: "complete"})
      Cache.delete(buf_key)

      Logger.info("Task force_complete", task_id: task_id, output_bytes: byte_size(output))
      {:ok, output}
    end
  end

  # ── 中断标记 ──────────────────────────────────────────────────────

  @doc """
  Set interrupt flag for a PTY session.

  Signals that next task poll should inject Ctrl+C to running process.
  Called by `Chat.interrupt!()`.

  ## Options
    * `pty_session_id` (string) — Session to interrupt.

  ## Returns
      `:ok`
  """
  def set_interrupt_flag(pty_session_id) do
    Cache.put(interrupt_key(pty_session_id), true)
    Logger.info("Interrupt flag set for #{pty_session_id}")
  end

  @doc """
  Check interrupt flag and clear if set.

  Internal use (called by LLM polling loop).

  ## Options
    * `pty_session_id` (string) — Session to check.

  ## Returns
      `true` if flag was set (now cleared)
      `false` if not set
  """
  def check_and_clear_interrupt_flag(pty_session_id) do
    key = interrupt_key(pty_session_id)
    case Cache.get(key) do
      true ->
        Cache.delete(key)
        Logger.info("Interrupt flag consumed for #{pty_session_id}")
        true
      _ -> false
    end
  end

  # ── 超时窗口 ──────────────────────────────────────────────────────

  @doc """
  Trigger timeout notification window for a task.

  Injects a message into LLM history telling it to wrap up gracefully.
  Multiple triggers stack (depth increases).

  Called via `trigger_timeout_window(pty_session_id)` in IEx.

  ## Options
    * `pty_session_id` (string) — Session to timeout.
    * `depth` (integer) — Recursion depth. Default: `1`

  ## Returns
      `:ok`
  """
  def trigger_timeout_window(pty_session_id, depth \\ 1) do
    Cache.put(window_key(pty_session_id), depth)
    Logger.info("Timeout window triggered for #{pty_session_id}, depth: #{depth}")
  end

  @doc """
  Check timeout window and decrement if active.

  Internal use (called by LLM polling loop on each iteration).

  ## Options
    * `pty_session_id` (string) — Session to check.

  ## Returns
      `"The timeout you set has been reached..."` message if window active
      `nil` if no timeout set
  """
  def check_timeout_window(pty_session_id) do
    key = window_key(pty_session_id)
    case Cache.get(key) do
      depth when is_integer(depth) and depth > 0 ->
        Cache.put(key, depth - 1)
        Logger.info("Timeout window consumed for #{pty_session_id}, remaining: #{depth - 1}")
        "The timeout you set has been reached. Please safely stop what you're doing and reply now."
      _ ->
        Cache.delete(key)
        nil
    end
  end

  # ── 内部 ──────────────────────────────────────────────────────────

  defp find_first(subject, pattern) do
    case :binary.match(subject, pattern) do
      {pos, len} -> {pos, len}
      :nomatch -> nil
    end
  end

  defp window_key(pty_session_id), do: "agent:#{pty_session_id}:timeout_window"
  defp interrupt_key(pty_session_id), do: "agent:#{pty_session_id}:interrupt_flag"
end
