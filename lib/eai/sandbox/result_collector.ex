defmodule Eai.ResultCollector do
  @moduledoc """
  基于镜像双倍回显（奇偶校验）的无状态流式收集器。
  只截取第 2 次 START 和第 2 次 END 之间的纯净执行结果。
  同时提供超时提醒窗口（深度计数器）和中断标记（文件管道）机制。
  """

  alias Eai.Cache.Cache
  require Logger

  @left  Application.compile_env(:eai, [:sandbox, :sentinel_left], "___EAI_START___")
  @right Application.compile_env(:eai, [:sandbox, :sentinel_right], "___EAI_END___")

  defp sandbox_cfg(key), do: Application.fetch_env!(:eai, :sandbox) |> Keyword.fetch!(key)

  def sentinel_left,  do: @left
  def sentinel_right, do: @right

  # ── 任务初始化 ──────────────────────────────────────────────────────────────

  def init_task(task_id) do
    Cache.put("result:#{task_id}", %{status: "collecting"})
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

    buffer  = Cache.get(buf_key) || ""
    new_buf = buffer <> data

    if debug? do
      Logger.debug("RAW new_buf", task_id: task_id, size: byte_size(new_buf), buffer: inspect(new_buf, binary: :as_buffer))
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
      case {find_nth(clean_buf, @left, 2), find_nth(clean_buf, @right, 2)} do
        {{start_pos, start_len}, {end_pos, _end_len}} ->
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
      %{status: status}         -> %{output: "",       status: status}
      nil                       -> nil
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
      IO.puts("Buffer (#{byte_size(buffer)} bytes): #{inspect(buffer, binary: :as_buffer, limit: 1000)}")
      IO.puts("=== END FORCE COMPLETE ===\n")
    end

    if current && current.status == "complete" do
      {:ok, current.output}
    else
      output =
        case {find_nth(buffer, @left, 2), find_nth(buffer, @right, 2)} do
          {{start_pos, start_len}, {end_pos, _end_len}} ->
            core_start = start_pos + start_len
            core_len = max(end_pos - core_start, 0)
            buffer |> :binary.part(core_start, core_len) |> String.trim()

          _ ->
            case find_nth(buffer, @left, 2) do
              {start_pos, start_len} ->
                buffer
                |> :binary.part(start_pos + start_len, byte_size(buffer) - start_pos - start_len)
                |> String.trim()

              nil ->
                buffer |> String.trim()
            end
        end

      Cache.put(res_key, %{output: output, status: "complete"})
      Cache.delete(buf_key)
      Logger.info("ResultCollector force_complete", task_id: task_id, output_bytes: byte_size(output))
      {:ok, output}
    end
  end

  # ── 超时提醒窗口（深度计数器，文件管道跨进程共享） ────────────────────────

  defp window_file(agent_id), do: Path.join(System.tmp_dir!(), "eai_timeout_#{agent_id}")

  @doc """
  触发超时提醒窗口：在临时文件中写入超时深度。
  每次模型调用 get_task_result 时会消耗一层深度并返回提醒消息。
  """
  def trigger_timeout_window(agent_id, depth \\ 1) do
    File.write!(window_file(agent_id), Integer.to_string(depth))
    Logger.info("Timeout window triggered for #{agent_id}, depth: #{depth} (file)")
  end

  @doc """
  检查当前超时窗口深度。如果 >0，消耗一层并返回提醒消息；否则删除文件并返回 nil。
  """
  def check_timeout_window(agent_id) do
    file = window_file(agent_id)
    if File.exists?(file) do
      case File.read(file) do
        {:ok, content} ->
          case Integer.parse(String.trim(content)) do
            {depth, _} when depth > 0 ->
              File.write!(file, Integer.to_string(depth - 1))
              Logger.info("Timeout window consumed for #{agent_id}, remaining: #{depth - 1}")
              "The timeout you set has been reached. Please safely stop what you're doing and reply now."
            _ ->
              File.rm(file)
              nil
          end
        _ ->
          nil
      end
    else
      nil
    end
  end

  # ── 中断标记（强制中断，文件管道） ───────────────────────────────────────

  defp interrupt_flag_file(agent_id), do: Path.join(System.tmp_dir!(), "eai_interrupt_#{agent_id}")

  @doc "设置强制中断标记"
  def set_interrupt_flag(agent_id) do
    File.write!(interrupt_flag_file(agent_id), "1")
    Logger.info("Interrupt flag set for #{agent_id}")
  end

  @doc "检查并清除中断标记，返回 true/false"
  def check_and_clear_interrupt_flag(agent_id) do
    file = interrupt_flag_file(agent_id)
    if File.exists?(file) do
      File.rm(file)
      Logger.info("Interrupt flag consumed for #{agent_id}")
      true
    else
      false
    end
  end

  # ── 哨兵定位工具 ──────────────────────────────────────────────────────────

  defp find_nth(subject, pattern, nth) do
    do_find_nth(subject, pattern, nth, 0)
  end

  defp do_find_nth(_subject, _pattern, 0, _offset), do: nil

  defp do_find_nth(subject, pattern, n, offset) do
    scope_start = offset
    scope_size = byte_size(subject) - scope_start

    case :binary.match(subject, pattern, scope: {scope_start, scope_size}) do
      {pos, len} ->
        if n == 1 do
          {pos, len}
        else
          do_find_nth(subject, pattern, n - 1, pos + len)
        end
      :nomatch ->
        nil
    end
  end
end