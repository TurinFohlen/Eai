defmodule Eai.Chat do
  @moduledoc "Main conversation GenServer managing multi-session chat history and async LLM tasks."

  use GenServer
  require Logger
  alias Eai.Adapter.Anthropic, as: AdapterAnthropic
  alias Eai.Adapter.OpenAI, as: AdapterOpenAI
  alias Eai.LLM.Direct
  alias Eai.Message
  alias Eai.ResultCollector
  alias Eai.Utils
  # ── 客户端 API ───────────────────────────────────────────────────

  @doc """
  发送一条独立消息（用于子代理调用），不累积主会话历史。
  返回 {:ok, reply} 或 {:error, reason}。

  可选 opts:
    pty_session_id:  "my_agent"   # PTY session ID（默认 \"default\"）
    chat_session_id: "my_session" # Chat 历史 session ID（默认 \"default\"）
    model:           :gpt4o
    prompt:          :coder
  """
  def send(message, opts \\ []) do
    pty_session_id  = Keyword.get(opts, :pty_session_id,  "default")
    chat_session_id = Keyword.get(opts, :chat_session_id, "default") |> to_string()
    model_opt       = Keyword.get(opts, :model)
    prompt_opt      = Keyword.get(opts, :prompt)
    run_opts        = build_run_opts(model_opt, prompt_opt, chat_session_id)
    messages        = [Message.new(:user, Utils.sanitize_value(message))]
    case Direct.run(messages, pty_session_id, run_opts) do
      {:ok, reply, _history}     -> {:ok, reply}
      {:error, reason, _history} -> {:error, reason}
    end
  end

  def start_link(_opts \\ []) do
    GenServer.start_link(__MODULE__, [], name: Eai.Naming.chat())
  end

  @doc """
  统一对话入口。

  ## 交互式多行模式（human / :h）
      进入后逐行输入，`/s` 发送，`/c` 取消。
      发送后立即返回 iex 提示符，任务在后台运行，结果自动打印。
      可以随时调用 `Eai.Chat.interrupt!` 中断。

      iex> Eai.Chat.talk
      iex> Eai.Chat.talk(mod: :h, timeout: 10_000)
      iex> Eai.Chat.talk(model: :gpt4o)
      iex> Eai.Chat.talk(prompt: :coder)
      iex> Eai.Chat.talk(chat_session: \"work\")

  ## 单行消息模式（function / :f）
      同步等待回复，返回 {:ok, reply} 或 {:error, reason}。

      iex> Eai.Chat.talk(content: \"帮我查一下时间\")
      iex> Eai.Chat.talk(mod: :f, content: \"查时间\", timeout: 30_000)
      iex> Eai.Chat.talk(content: \"hi\", model: :claude_sonnet, prompt: :analyst)
      iex> Eai.Chat.talk(content: \"继续\", chat_session: \"work\")

  ## model / prompt / chat_session 参数
      model / prompt 传 models.exs / prompts.exs 中定义的 :name atom。
      chat_session 传字符串，省略时使用 \"default\" 会话。

      iex> Eai.Models.names()         # 查看所有可用模型
      iex> Eai.Prompts.list()         # 查看所有可用 prompt
      iex> Eai.Chat.list_chat_sessions()  # 查看所有会话
  """
  def talk(opts \\ []) do
    timeout      = Keyword.get(opts, :timeout, :infinity)
    mode         = Keyword.get(opts, :mod, :human)
    content      = Keyword.get(opts, :content)
    model_opt    = Keyword.get(opts, :model)
    prompt_opt   = Keyword.get(opts, :prompt)
    chat_session = opts |> Keyword.get(:chat_session, "default") |> to_string()

    case {mode, content} do
      {m, nil} when m in [:h, :human] ->
        case GenServer.call(Eai.Naming.chat(), {:status, chat_session}) do
          :busy ->
            IO.puts("A task is already running in session '#{chat_session}'. Please wait or interrupt it first.")
            {:error, :busy}
          _ ->
            IO.puts("EAI Chat [#{chat_session}]. Type '/s' on a new line to send your message. Type '/c' on a new line to cancel")
            read_lines(timeout, model_opt, prompt_opt, chat_session, [])
            :ok
        end

      {m, msg} when not is_nil(msg) and m in [:f, :function, :h, :human] ->
        GenServer.call(Eai.Naming.chat(), {:talk, msg, timeout, model_opt, prompt_opt, chat_session}, :infinity)

      {m, _} ->
        IO.puts("Invalid mod: #{inspect(m)}. Use :h/:human (interactive) or :f/:function (single-line with content).")
        {:error, :invalid_mod}
    end
  end

  def get_history(chat_session \\ "default") do
    GenServer.call(Eai.Naming.chat(), {:get_history, to_string(chat_session)})
  end

  @doc """
  强制中断：设置中断标记，模型在下次轮询结果时会自动注入 Ctrl+C。
  仅在异步交互模式下有效（同步模式会阻塞，无法调用此函数）。
  """
  def interrupt!(chat_session \\ "default") do
    GenServer.call(Eai.Naming.chat(), {:interrupt!, to_string(chat_session)})
  end

  @doc "显式关闭一个会话，释放其历史记录。不能关闭 \"default\" 会话。"
  def close_chat_session(name) do
    GenServer.call(Eai.Naming.chat(), {:close_chat_session, to_string(name)})
  end

  @doc "列出所有活跃会话及其消息数和状态。"
  def list_chat_sessions do
    GenServer.call(Eai.Naming.chat(), :list_chat_sessions)
  end

  @doc """
  导出指定会话的对话历史为 Record 兼容的 gzip 文件。
  由 LLM 工具 `export_context` 或用户手动调用。
  """
  def export_history(file_path, chat_session \\ "default") do
    GenServer.call(Eai.Naming.chat(), {:export_history, file_path, to_string(chat_session)})
  end

  @doc """
  从 Record 兼容的 gzip 文件加载消息列表，替换指定会话的对话历史。

  format 参数:
    \"converse\" (默认) — 消息已是 Eai.Message IR 格式
    \"openai\"         — 消息为 OpenAI 格式，需要适配器转换
    \"anthropic\"      — 消息为 Anthropic 格式，需要适配器转换
  """
  def replace_history(file_path, chat_session \\ "default", format \\ "converse") do
    GenServer.call(Eai.Naming.chat(), {:replace_history, file_path, to_string(chat_session), format})
  end

  # ── 私有：多行读取循环 ──────────────────────────────────────────

  defp read_lines(timeout, model_opt, prompt_opt, chat_session, lines) do
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
            submit_or_restart(message, timeout, model_opt, prompt_opt, chat_session)

          trimmed == "/c" ->
            IO.puts("Cancelled.")

          true ->
            read_lines(timeout, model_opt, prompt_opt, chat_session, [trimmed | lines])
        end
    end
  end

  defp submit_or_restart(message, timeout, model_opt, prompt_opt, chat_session) do
    if String.trim(message) == "" do
      IO.puts("No message to send. Starting over.")
      read_lines(timeout, model_opt, prompt_opt, chat_session, [])
    else
      GenServer.cast(Eai.Naming.chat(), {:talk_async, message, timeout, model_opt, prompt_opt, chat_session})
      IO.puts("Task submitted. Use Eai.Chat.interrupt!(\"#{chat_session}\") to stop it.")
    end
  end

  # ── 服务端回调 ───────────────────────────────────────────────────

  @impl true
  def init(_) do
    {:ok, %{
      sessions:       %{"default" => new_session()},
      ref_to_session: %{}
    }}
  end

  @impl true
  def handle_call({:status, chat_session_id}, _from, state) do
    session = get_session(state, chat_session_id)
    {:reply, (if is_nil(session.task_ref), do: :idle, else: :busy), state}
  end

  @impl true
  def handle_call({:talk, text, timeout, model_opt, prompt_opt, chat_session_id}, from, state) do
    session = get_session(state, chat_session_id)
    if is_nil(session.task_ref) do
      sanitized    = Utils.sanitize_value(text)
      user_msg     = Message.new(:user, sanitized)
      new_messages = session.messages ++ [user_msg]
      pty_session_id = chat_session_id
      run_opts       = build_run_opts(model_opt, prompt_opt, chat_session_id)

      task = Task.async(fn -> Direct.run(new_messages, pty_session_id, run_opts) end)
      Process.unlink(task.pid)

      remind_timer =
        if timeout != :infinity and is_integer(timeout) and timeout > 0 do
          Process.send_after(self(), {:remind_model, pty_session_id, chat_session_id}, timeout)
        end

      new_session = %{session | messages: new_messages, from: from, task_ref: task.ref, remind_timer: remind_timer}
      new_state   = state |> put_session(chat_session_id, new_session) |> put_ref(task.ref, chat_session_id)

      {:noreply, new_state}
    else
      {:reply, {:error, :busy, "Another task is running in session '#{chat_session_id}'."}, state}
    end
  end

  @impl true
  def handle_call({:interrupt!, chat_session_id}, _from, state) do
    session = get_session(state, chat_session_id)
    if is_nil(session.task_ref) do
      {:reply, {:error, :no_task}, state}
    else
      ResultCollector.set_interrupt_flag(chat_session_id)
      {:reply, :ok, state}
    end
  end

  @impl true
  def handle_call({:get_history, chat_session_id}, _from, state) do
    {:reply, get_session(state, chat_session_id).messages, state}
  end

  @impl true
  def handle_call(:list_chat_sessions, _from, state) do
    result = Map.new(state.sessions, fn {id, session} ->
      {id, %{
        message_count: length(session.messages),
        status:        (if is_nil(session.task_ref), do: "idle", else: "busy")
      }}
    end)
    {:reply, result, state}
  end

  @impl true
  def handle_call({:close_chat_session, "default"}, _from, state) do
    {:reply, {:error, :cannot_close_default}, state}
  end

  @impl true
  def handle_call({:close_chat_session, name}, _from, state) do
    case Map.fetch(state.sessions, name) do
      :error ->
        {:reply, {:error, :not_found}, state}
      {:ok, session} when not is_nil(session.task_ref) ->
        {:reply, {:error, :session_busy}, state}
      {:ok, _session} ->
        {:reply, :ok, %{state | sessions: Map.delete(state.sessions, name)}}
    end
  end

  @impl true
  def handle_call({:export_history, file_path, chat_session_id}, _from, state) do
    session = get_session(state, chat_session_id)
    result  = try do
      File.mkdir_p!(Path.dirname(file_path))
      sanitized  = Utils.sanitize_messages(session.messages)
      compressed = :zlib.gzip(:erlang.term_to_binary(sanitized))
      File.write!(file_path, compressed)
      {:ok, file_path}
    rescue
      e -> {:error, Exception.message(e)}
    end
    {:reply, result, state}
  end

  @impl true
  def handle_call({:replace_history, file_path, chat_session_id, format}, _from, state) do
    result = try do
      compressed   = File.read!(file_path)
      decompressed = :zlib.gunzip(compressed)
      raw          = :erlang.binary_to_term(decompressed)
      messages     = convert_imported_messages(raw, format)
      {:ok, messages}
    rescue
      e -> {:error, Exception.message(e)}
    end

    case result do
      {:ok, messages} ->
        new_session = %{get_session(state, chat_session_id) | messages: messages}
        {:reply, {:ok, length(messages)}, put_session(state, chat_session_id, new_session)}
      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_cast({:talk_async, text, timeout, model_opt, prompt_opt, chat_session_id}, state) do
    session        = get_session(state, chat_session_id)
    sanitized      = Utils.sanitize_value(text)
    user_msg       = Message.new(:user, sanitized)
    new_messages   = session.messages ++ [user_msg]
    pty_session_id = chat_session_id
    run_opts       = build_run_opts(model_opt, prompt_opt, chat_session_id)

    task = Task.async(fn -> Direct.run(new_messages, pty_session_id, run_opts) end)
    Process.unlink(task.pid)

    remind_timer =
      if timeout != :infinity and is_integer(timeout) and timeout > 0 do
        Process.send_after(self(), {:remind_model, pty_session_id, chat_session_id}, timeout)
      end

    new_session = %{session | messages: new_messages, task_ref: task.ref, remind_timer: remind_timer, from: nil}
    new_state   = state |> put_session(chat_session_id, new_session) |> put_ref(task.ref, chat_session_id)

    {:noreply, new_state}
  end

  # ── 消息处理 ─────────────────────────────────────────────────────

  # 任务正常完成：{ref, result} + 从 ref_to_session 反查 chat_session_id
  @impl true
  def handle_info({ref, result}, state) when is_reference(ref) do
    case Map.pop(state.ref_to_session, ref) do
      {nil, _} ->
        # 非 ref 或不属于此 GenServer 的 Task，忽略
        {:noreply, state}

      {chat_session_id, new_ref_map} ->
        session = get_session(state, chat_session_id)
        if session.remind_timer, do: Process.cancel_timer(session.remind_timer)

        {reply_to_caller, new_messages} = case result do
          {:ok, reply, full_history} ->
            IO.puts("\n🧙‍♀️ Assistant [##{chat_session_id}]: #{reply}")
            {{:ok, reply}, full_history}
          {:error, reason, partial_history} ->
            {{:error, reason}, partial_history}
        end

        Phoenix.PubSub.broadcast(Eai.Naming.pubsub(), "chat_updates:#{chat_session_id}", {:new_message, new_messages})

        if session.from, do: GenServer.reply(session.from, reply_to_caller)

        new_session = %{session | messages: new_messages, task_ref: nil, from: nil, remind_timer: nil}
        new_state   = %{state | ref_to_session: new_ref_map}
                      |> put_session(chat_session_id, new_session)

        {:noreply, new_state}
    end
  end

  # 任务崩溃：处理 :DOWN 消息
  @impl true
  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    case Map.pop(state.ref_to_session, ref) do
      {nil, _} ->
        {:noreply, state}

      {chat_session_id, new_ref_map} ->
        session = get_session(state, chat_session_id)
        if session.remind_timer, do: Process.cancel_timer(session.remind_timer)
        Logger.error("Chat: task crashed in session '#{chat_session_id}' — #{inspect(reason)}")

        Phoenix.PubSub.broadcast(Eai.Naming.pubsub(), "chat_updates:#{chat_session_id}", {:new_message, session.messages})

        if session.from, do: GenServer.reply(session.from, {:error, {:task_crashed, reason}})

        new_session = %{session | task_ref: nil, from: nil, remind_timer: nil}
        new_state   = %{state | ref_to_session: new_ref_map}
                      |> put_session(chat_session_id, new_session)

        {:noreply, new_state}
    end
  end

  # 超时提醒
  @impl true
  def handle_info({:remind_model, pty_session_id, chat_session_id}, state) do
    Logger.info("Chat: timeout reached, triggering timeout window for pty=#{pty_session_id} chat=#{chat_session_id}")
    ResultCollector.trigger_timeout_window(pty_session_id)
    case Map.fetch(state.sessions, chat_session_id) do
      {:ok, session} ->
        {:noreply, put_session(state, chat_session_id, %{session | remind_timer: nil})}
      :error ->
        {:noreply, state}
    end
  end

  # 其他一切消息
  @impl true
  def handle_info(_msg, state), do: {:noreply, state}

  # ── 内部辅助函数 ─────────────────────────────────────────────────

  defp new_session,
    do: %{messages: [], from: nil, task_ref: nil, remind_timer: nil}

  defp get_session(state, id),
    do: Map.get(state.sessions, id, new_session())

  defp put_session(state, id, session),
    do: %{state | sessions: Map.put(state.sessions, id, session)}

  defp put_ref(state, ref, session_id),
    do: %{state | ref_to_session: Map.put(state.ref_to_session, ref, session_id)}

  defp build_run_opts(model_opt, prompt_opt, chat_session_id) do
    %{chat_session_id: chat_session_id}
    |> then(fn m -> if model_opt,  do: Map.put(m, :model,         model_opt),  else: m end)
    |> then(fn m -> if prompt_opt, do: Map.put(m, :system_prompt, prompt_opt), else: m end)
  end

  # Convert imported raw messages to Eai.Message IR based on format
  defp convert_imported_messages(raw_messages, "converse") do
    # Already in Converse/Eai.Message format (from erlang term)
    raw_messages
  end

  defp convert_imported_messages(raw_messages, "openai") do
    AdapterOpenAI.from_messages(raw_messages)
  end

  defp convert_imported_messages(raw_messages, "anthropic") do
    AdapterAnthropic.from_messages(raw_messages)
  end

  defp convert_imported_messages(raw_messages, _unknown) do
    # Default: assume converse format
    raw_messages
  end
end
