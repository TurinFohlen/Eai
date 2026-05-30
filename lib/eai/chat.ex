defmodule Eai.Chat do
  use GenServer
  require Logger
  alias Eai.LLM.Direct
  alias Eai.ResultCollector
  alias Eai.Utils

  # ── 客户端 API ───────────────────────────────────────────────────

  @doc """
  发送一条独立消息（用于子代理调用），不累积主会话历史。
  返回 {:ok, reply} 或 {:error, reason}。
  """
  def send(message, opts \\ []) do
    agent_id = Keyword.get(opts, :agent_id, "default")
    messages = [%{role: "user", content: Utils.sanitize_value(message)}]
    case Direct.run(messages, agent_id) do
      {:ok, reply, _history} -> {:ok, reply}
      {:error, reason, _history} -> {:error, reason}
    end
  end

  def start_link(_opts \\ []) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @doc """
  统一对话入口。

  ## 交互式多行模式（human / :h）
      进入后逐行输入，`/s` 发送，`/c` 取消。
      发送后立即返回 iex 提示符，任务在后台运行，结果自动打印。
      可以随时调用 `Eai.Chat.interrupt!` 中断。

      iex> Eai.Chat.talk
      iex> Eai.Chat.talk(mod: :h, timeout: 10_000)

  ## 单行消息模式（function / :f）
      同步等待回复，返回 {:ok, reply} 或 {:error, reason}。
      iex> Eai.Chat.talk(content: "帮我查一下时间")
      iex> Eai.Chat.talk(mod: :f, content: "查时间", timeout: 30_000)
  """
  def talk(opts \\ []) do
    timeout = Keyword.get(opts, :timeout, :infinity)
    mode    = Keyword.get(opts, :mod, :human)
    content = Keyword.get(opts, :content)

    case {mode, content} do
      {m, nil} when m in [:h, :human] ->
        # 交互式多行模式
        case GenServer.call(__MODULE__, :status) do
          :busy ->
            IO.puts("A task is already running. Please wait for it to finish, or interrupt it before starting a new conversation.")
            {:error, :busy}
          _ ->
            IO.puts("EAI Chat. Type '/s' on a new line to send your message. Type '/c' on a new line to cancel")
            read_lines(timeout, [])
            :ok   # 注意：这里返回 :ok 仅表示输入流结束，不代表任务完成
        end

      {m, msg} when not is_nil(msg) and m in [:f, :function, :h, :human] ->
        # 单行消息模式（同步）
        GenServer.call(__MODULE__, {:talk, msg, timeout}, :infinity)

      {m, _} ->
        IO.puts("Invalid mod: #{inspect(m)}. Use :h/:human (interactive) or :f/:function (single-line with content).")
        {:error, :invalid_mod}
    end
  end

  def get_history do
    GenServer.call(__MODULE__, :get_history)
  end

  @doc """
  强制中断：设置中断标记，模型在下次轮询结果时会自动注入 Ctrl+C。
  仅在异步交互模式下有效（同步模式会阻塞，无法调用此函数）。
  """
  def interrupt! do
    GenServer.call(__MODULE__, :interrupt!)
  end

  # ── 私有：多行读取循环 ──────────────────────────────────────────

  defp read_lines(timeout, lines) do
    case IO.gets("> ") do
      :eof ->
        IO.puts("Cancelled.")

      {:error, reason} ->
        IO.puts("Error: #{inspect(reason)}")

      line ->
        trimmed = String.trim(line)

        cond do
          trimmed == "/s" ->
            message = Enum.join(Enum.reverse(lines), "\n")

            if String.trim(message) == "" do
              IO.puts("No message to send. Starting over.")
              read_lines(timeout, [])
            else
              # 异步发送，不阻塞
              GenServer.cast(__MODULE__, {:talk_async, message, timeout})
              IO.puts("Task submitted. You can continue using the shell. Use Eai.Chat.interrupt! to stop it.")
              # 立即返回 iex，不再等待
            end

          trimmed == "/c" ->
            IO.puts("Cancelled.")

          true ->
            read_lines(timeout, [trimmed | lines])
        end
    end
  end

  # ── 服务端回调 ───────────────────────────────────────────────────

  @impl true
  def init(_) do
    {:ok, %{
      messages: [],
      from: nil,
      task_ref: nil,
      remind_timer: nil
    }}
  end

  @impl true
  def handle_call(:status, _from, %{from: from} = state) do
    if is_nil(from) do
      {:reply, :idle, state}
    else
      {:reply, :busy, state}
    end
  end

  # 同步发送（单行模式）
  @impl true
  def handle_call({:talk, _text, _timeout}, _from, %{from: from} = state)
    when not is_nil(from) do
    {:reply, {:error, :busy, "Another task is running. Please wait."}, state}
  end

  @impl true
  def handle_call({:talk, text, timeout}, from, %{messages: messages} = state) do
    sanitized = Utils.sanitize_value(text)
    new_messages = messages ++ [%{role: "user", content: sanitized}]

    task = Task.async(fn -> Direct.run(new_messages) end)

    remind_timer =
      if timeout != :infinity and is_integer(timeout) and timeout > 0 do
        Process.send_after(self(), {:remind_model, "default"}, timeout)
      end

    state = %{state | messages: new_messages, from: from, task_ref: task.ref,
              remind_timer: remind_timer}

    {:noreply, state}
  end

  @impl true
  def handle_call(:interrupt!, _from, %{task_ref: nil} = state) do
    {:reply, {:error, :no_task}, state}
  end

  @impl true
  def handle_call(:interrupt!, _from, state) do
    ResultCollector.set_interrupt_flag("default")
    {:reply, :ok, state}
  end

  @impl true
  def handle_call(:get_history, _from, state) do
    {:reply, state.messages, state}
  end

  # 异步发送（交互模式）
  @impl true
  def handle_cast({:talk_async, text, timeout}, %{messages: messages} = state) do
    sanitized = Utils.sanitize_value(text)
    new_messages = messages ++ [%{role: "user", content: sanitized}]

    task = Task.async(fn -> Direct.run(new_messages) end)

    remind_timer =
      if timeout != :infinity and is_integer(timeout) and timeout > 0 do
        Process.send_after(self(), {:remind_model, "default"}, timeout)
      end

    # 注意：异步模式下 `from` 设为 nil，handle_info 中通过判断 nil 来打印而非 reply
    state = %{state | messages: new_messages, task_ref: task.ref,
              remind_timer: remind_timer, from: nil}

    {:noreply, state}
  end

  # ── 消息处理 ─────────────────────────────────────────────────────

  @impl true
  def handle_info({ref, result}, %{task_ref: ref, from: from} = state) do
    if state.remind_timer, do: Process.cancel_timer(state.remind_timer)
    state = %{state | task_ref: nil, remind_timer: nil, from: nil}

    case result do
      {:ok, reply, full_history} ->
        IO.puts("\n🎙️ Assistant: #{reply}")
        if from do
          GenServer.reply(from, {:ok, reply})
        end
        {:noreply, %{state | messages: full_history}}

      {:error, reason, partial_history} ->
        if from do
          GenServer.reply(from, {:error, reason})
        end
        {:noreply, %{state | messages: partial_history}}
    end
  end

  # 超时提醒
  @impl true
  def handle_info({:remind_model, agent_id}, state) do
    Logger.info("Chat: timeout reached, triggering timeout window for #{agent_id}")
    ResultCollector.trigger_timeout_window(agent_id)
    {:noreply, %{state | remind_timer: nil}}
  end

  # 忽略不匹配的任务结果
  @impl true
  def handle_info({_ref, _result}, state), do: {:noreply, state}

  # 其他一切消息
  @impl true
  def handle_info(_msg, state), do: {:noreply, state}
end