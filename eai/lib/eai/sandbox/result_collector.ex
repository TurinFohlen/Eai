defmodule Eai.ResultCollector do
  @moduledoc """
  基于镜像双倍回显（奇偶校验）的无状态流式收集器。
  只截取第 2 次 START 和第 2 次 END 之间的纯净执行结果。
  """

  alias Eai.Cache.Cache
  require Logger

  @left  "___EAI_START___"
  @right "___EAI_END___"

  def sentinel_left,  do: @left
  def sentinel_right, do: @right

  def init_task(task_id) do
    Cache.put("result:#{task_id}", %{status: "collecting"})
    Cache.put("result:#{task_id}:buffer", "")
  end

  def collect(task_id, data) do
    data = Eai.Utils.sanitize_value(data)   # ← 先清洗，确保后续操作安全
    buf_key = "result:#{task_id}:buffer"
    res_key = "result:#{task_id}"

    buffer  = Cache.get(buf_key) || ""
    new_buf = buffer <> data

    # 🔍 调试日志：直接观察原始流入数据
    Logger.debug("RAW new_buf: #{inspect(new_buf, limit: :infinity)}")

    # ✅ 清洗：统一换行、去除 ANSI 控制码、移除干扰的 \r
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
          Cache.put(buf_key, clean_buf)   # 注意这里也存清洗后的数据，保证后续拼接一致
          :collecting
      end
    end
  end

  def get(task_id) do
    case Cache.get("result:#{task_id}") do
      %{status: "complete"} = r -> %{output: r.output, status: "complete"}
      %{status: status}         -> %{output: "",       status: status}
      nil                       -> nil
    end
  end

  # ── 修正后的 find_nth：正确地按 offset 递进 ──────────────────────

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
          # 下一次从当前匹配项之后继续搜索
          do_find_nth(subject, pattern, n - 1, pos + len)
        end
      :nomatch ->
        nil
    end
  end
end
