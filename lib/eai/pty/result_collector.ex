defmodule Eai.ResultCollector do
  @moduledoc """
  基于单次哨兵匹配的无状态流式收集器。
  截取第 1 次 START 和第 1 次 END 之间的纯净执行结果。
  （PTY 命令行用 base64 包装哨兵，回显中不再出现明文哨兵，无需奇偶校验。）
  同时提供超时提醒窗口（深度计数器）和中断标记（Cache）机制。
  """

  alias Eai.Cache.Cache
  require Logger

  @left Application.compile_env(:eai, [:sandbox, :sentinel_left])
  @right Application.compile_env(:eai, [:sandbox, :sentinel_right])

  defp sandbox_cfg(key), do: Application.fetch_env!(:eai, :sandbox) |> Keyword.fetch!(key)

  def sentinel_left, do: @left
  def sentinel_right, do: @right

  # ── 任务初始化 ──────────────────────────────────────────────────────────────

  def init_task(task_id) do
    Cache.put("result:#{task_id}", %{
      status: "collecting",
      started_at: System.monotonic_time(:millisecond)
    })

    Cache.put("result:#{task_id}:buffer", "")
  end

  # ── 流式收集（PTY 输出） ─────────────────────────────────────────────────────

  def collect(task_id, data) do
    debug? = sandbox_cfg(:debug_pty_output)

    if debug? do
      IO.puts("\n=== PTY RAW OUTPUT ===")
      IO.puts(inspect(data, binary: :as_buffer, limit: :infinity))
      IO.puts("=== END PTY RAW ===\n")
    end

    data = Eai.Utils.sanitize_value(data)
    buf_key = "result:#{task_id}:buffer"
    res_key = "result:#{task_id}"

    buffer = Cache.get(buf_key) || ""
    new_buf = buffer <> data

    if debug? do
      Logger.debug("RAW new_buf",
        task_id: task_id,
        size: byte_size(new_buf),
        buffer: inspect(new_buf)
      )
    else
      Logger.debug("RAW new_buf", task_id: task_id, size: byte_size(new_buf))
    end

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

  # ── 查询结果 ────────────────────────────────────────────────────────────────

  def get(task_id) do
    case Cache.get("result:#{task_id}") do
      %{status: "complete"} = r -> %{output: r.output, status: "complete"}
      %{status: status} = r -> %{status: status, started_at: Map.get(r, :started_at)}
      nil -> nil
    end
  end

  # ── 超时强制收集（无注入，仅提取已有数据） ─────────────────────────────────

  @doc """
  超时时强制取出 buffer 中已有的全部数据，尽力提取有效内容后标记完成。
  """
  def force_complete(task_id) do
    debug? = sandbox_cfg(:debug_pty_output)

    buf_key = "result:#{task_id}:buffer"
    res_key = "result:#{task_id}"

    buffer = Cache.get(buf_key) || ""
    current = Cache.get(res_key)

    if debug? do
      IO.puts("\n=== PTY FORCE COMPLETE ===")

      IO.puts(
        "Buffer (#{byte_size(buffer)} bytes): #{inspect(buffer, binary: :as_buffer, limit: 1000)}"
      )

      IO.puts("=== END FORCE COMPLETE ===\n")
    end

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
            # 有左哨兵但没有右哨兵：取左哨兵之后的全部内容
            buffer
            |> :binary.part(start_pos + start_len, byte_size(buffer) - start_pos - start_len)
            |> String.trim()

          _ ->
            buffer |> String.trim()
        end

      Cache.put(res_key, %{output: output, status: "complete"})
      Cache.delete(buf_key)

      Logger.info("ResultCollector force_complete",
        task_id: task_id,
        output_bytes: byte_size(output)
      )

      {:ok, output}
    end
  end

  # ── 超时提醒窗口（深度计数器，Cache 跨进程共享） ─────────────────────────

  @doc """
  触发超时提醒窗口：在 Cache 中写入超时深度。
  每次模型调用 get_task_result 时会消耗一层深度并返回提醒消息。
  """
  def trigger_timeout_window(pty_session_id, depth \\ 1) do
    Cache.put(window_key(pty_session_id), depth)
    Logger.info("Timeout window triggered for #{pty_session_id}, depth: #{depth} (cache)")

    :telemetry.execute(
      [:eai, :result_collector, :timeout, :triggered],
      %{system_time: System.system_time()},
      %{pty_session_id: pty_session_id, depth: depth}
    )
  end

  @doc """
  检查当前超时窗口深度。如果 >0，消耗一层并返回提醒消息；否则清除并返回 nil。
  """
  def check_timeout_window(pty_session_id) do
    key = window_key(pty_session_id)

    case Cache.get(key) do
      depth when is_integer(depth) and depth > 0 ->
        Cache.put(key, depth - 1)
        Logger.info("Timeout window consumed for #{pty_session_id}, remaining: #{depth - 1}")

        :telemetry.execute(
          [:eai, :result_collector, :timeout, :consumed],
          %{system_time: System.system_time()},
          %{pty_session_id: pty_session_id, remaining: depth - 1}
        )

        "The timeout you set has been reached. Please safely stop what you're doing and reply now."

      _ ->
        Cache.delete(key)
        nil
    end
  end

  # ── 中断标记（强制中断，Cache） ──────────────────────────────────────────

  @doc "设置强制中断标记"
  def set_interrupt_flag(pty_session_id) do
    Cache.put(interrupt_key(pty_session_id), true)
    Logger.info("Interrupt flag set for #{pty_session_id}")

    :telemetry.execute(
      [:eai, :result_collector, :interrupt, :set],
      %{system_time: System.system_time()},
      %{pty_session_id: pty_session_id}
    )
  end

  @doc "检查并清除中断标记，返回 true/false"
  def check_and_clear_interrupt_flag(pty_session_id) do
    key = interrupt_key(pty_session_id)

    case Cache.get(key) do
      true ->
        Cache.delete(key)
        Logger.info("Interrupt flag consumed for #{pty_session_id}")
        true

      _ ->
        false
    end
  end

  # ── 内部工具 ────────────────────────────────────────────────────────────────

  defp find_first(subject, pattern) do
    case :binary.match(subject, pattern) do
      {pos, len} -> {pos, len}
      :nomatch -> nil
    end
  end

  defp window_key(pty_session_id), do: "agent:#{pty_session_id}:timeout_window"
  defp interrupt_key(pty_session_id), do: "agent:#{pty_session_id}:interrupt_flag"
end
