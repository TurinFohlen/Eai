defmodule Eai.Chat do
  use GenServer
  require Logger
  alias Eai.LLM.Direct
  alias Eai.ResultCollector
  alias Eai.Utils

  # ── 客户端 API ───────────────────────────────────────────────────

  def send(message, opts \\ []) do
    agent_id = Keyword.get(opts, :agent_id, "default")
    messages = [%{role: "user", content: Utils.sanitize_value(message)}]
    Direct.run(messages, agent_id)
  end

  def start_link(_opts \\ []) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @doc """
  发送消息，自动累积上下文。
  - `timeout`：超时提醒（毫秒），超时后通过 ResultCollector 的深度窗口提醒模型，不中断任务。
  `talk` 一直等待最终回复（调用方阻塞，但 GenServer 内部异步，仍可处理其他请求）。
  """
  def talk(text, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, :infinity)
    GenServer.call(__MODULE__, {:talk, text, timeout}, :infinity)
  end

  def get_history do
    GenServer.call(__MODULE__, :get_history)
  end

  @doc """
  强制中断：仅设置中断标记，不直接操作 PTY。
  模型在轮询任务结果时会自行发现中断，并触发 Ctrl+C 注入。
  """
  def interrupt! do
    GenServer.call(__MODULE__, :interrupt!)
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
    clean = Enum.filter(state.messages, fn m ->
      role = m[:role] || m["role"]
      role in ["user", "assistant"] and
        not (Map.has_key?(m, :tool_calls) or Map.has_key?(m, "tool_calls"))
    end)
    {:reply, clean, state}
  end

  # ── 消息处理（顺序重要：具体到通用） ─────────────────────────────

  @impl true
  def handle_info({ref, result}, %{task_ref: ref, from: from} = state) do
    if state.remind_timer, do: Process.cancel_timer(state.remind_timer)
    state = %{state | task_ref: nil, remind_timer: nil, from: nil}

    case result do
      {:ok, reply} ->
        updated = state.messages ++ [%{role: "assistant", content: reply}]
        IO.puts("\n🎙️ Assistant: #{reply}")
        GenServer.reply(from, {:ok, reply})
        {:noreply, %{state | messages: updated}}

      {:error, reason} ->
        GenServer.reply(from, {:error, reason})
        {:noreply, state}
    end
  end

  # 超时提醒
  @impl true
  def handle_info({:remind_model, agent_id}, state) do
    Logger.info("Chat: timeout reached, triggering timeout window for #{agent_id}")
    ResultCollector.trigger_timeout_window(agent_id)
    {:noreply, %{state | remind_timer: nil}}
  end

  # 忽略不匹配的任务结果（通用二元组消息）
  @impl true
  def handle_info({_ref, _result}, state), do: {:noreply, state}

  # 其他一切消息
  @impl true
  def handle_info(_msg, state), do: {:noreply, state}
end