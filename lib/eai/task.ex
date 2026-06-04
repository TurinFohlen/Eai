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

  @doc "流式收集 PTY 输出，哨兵匹配截取纯净结果"
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

  @doc "查询任务结果"
  def get(task_id) do
    case Cache.get("result:#{task_id}") do
      %{status: "complete"} = r -> %{output: r.output, status: "complete"}
      %{status: status} = r -> %{status: status, started_at: Map.get(r, :started_at)}
      nil -> nil
    end
  end

  @doc "超时强制收集：从 buffer 尽力提取有效内容"
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

  def set_interrupt_flag(pty_session_id) do
    Cache.put(interrupt_key(pty_session_id), true)
    Logger.info("Interrupt flag set for #{pty_session_id}")
  end

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

  def trigger_timeout_window(pty_session_id, depth \\ 1) do
    Cache.put(window_key(pty_session_id), depth)
    Logger.info("Timeout window triggered for #{pty_session_id}, depth: #{depth}")
  end

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
