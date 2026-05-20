defmodule Eai.Chat do
  alias Eai.LLM.Direct

  # ── 交互式循环（保留） ──────────────────────────────────────────────

  def start do
    IO.puts("EAI Chat. Type '/send' on a new line to send your message. Type 'exit' to quit.\n")
    loop([])
  end

  defp loop(messages) do
    IO.write("> ")
    buffer = read_until_send()
    if buffer == "exit" do
      IO.puts("Goodbye!")
      exit(0)
    end

    case buffer do
      "" ->
        loop(messages)
      _ ->
        new_messages = messages ++ [%{role: "user", content: buffer}]
        case Direct.run(new_messages) do
          {:ok, response} ->
            IO.puts("\n🤖 #{response}\n")
            loop(new_messages ++ [%{role: "assistant", content: response}])
          {:error, error} ->
            IO.puts("\n⚠️ Error: #{inspect(error)}\n")
            loop(messages)
        end
    end
  end

  defp read_until_send do
    lines = []
    read_lines(lines)
  end

  defp read_lines(lines) do
    case IO.gets("") |> String.trim_trailing() do
      "/send" ->
        Enum.join(Enum.reverse(lines), "\n")
      "exit" ->
        "exit"
      line ->
        read_lines([line | lines])
    end
  end

  # ── 单次发送（新增） ────────────────────────────────────────────────

  @doc """
  单次发送消息，直接返回 AI 回复。

  ## 示例

      iex> Eai.Chat.send("现在几点钟？")
      {:ok, "当前时间是 2025-01-15T10:30:00Z"}

      iex> Eai.Chat.send("列出活动会话", "my_agent")
      {:ok, "当前有 2 个活动会话..."}

  返回值是 `{:ok, response}` 或 `{:error, reason}`，
  与 `Direct.run/2` 保持一致，方便模式匹配。
  """
  def send(message, agent_id \\ "default") do
    messages = [%{role: "user", content: message}]
    Direct.run(messages, agent_id)
  end
end
