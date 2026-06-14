defmodule Eai.Chat do
  @moduledoc "Main conversation GenServer managing multi-session chat history and async LLM tasks."

  use GenServer
  require Logger
  alias Eai.Adapter.Anthropic, as: AdapterAnthropic
  alias Eai.Adapter.OpenAI, as: AdapterOpenAI
  alias Eai.LLM.Direct
  alias Eai.Message
  alias Eai.Task, as: TaskResult
  alias Eai.Utils

  # ── 客户端 API ───────────────────────────────────────────────────
  def start_link(_opts \\ []) do
    GenServer.start_link(__MODULE__, [], name: Eai.Naming.chat())
  end

  @doc """
  Send a message to LLM and get response (or enter interactive mode).

  ## Options

    * `:content` (string) — User message. Required for `:function` mode.
    * `:mod` (`:function` | `:human`) — Execution mode. Default: `:human`
      - `:function` — one-shot, synchronous, returns `{:ok, reply}` or `{:error, reason}`
      - `:human` — interactive, type `/s` to send, `/c` to cancel
    * `:timeout` (integer) — Max wait for reply in milliseconds. Default: `:infinity`

    * `:model` (atom) — Model name: `:deepseek`, `:claude_opus`, `:gpt4o`, etc.
                        Default: `:deepseek`
    * `:prompt` (atom) — System prompt: `:coder`, `:analyst`, `:momoka`, etc.
                         Default: `:momoka`
    * `:chara_card` (atom) — Override model + prompt with character card.
                             Example: `:backend_engineer`. Overrides `:model` and `:prompt`.

    * `:chat_session` (string) — Conversation history isolation. Default: `"default"`
    * `:pty_session_id` (string) — PTY sandbox isolation. Default: same as `:chat_session`

  ## Examples

      # Interactive
      iex> Eai.Chat.talk()

      # One-shot, defaults
      iex> Eai.Chat.talk(content: "what time is it?", mod: :function)

      # With model + prompt
      iex> Eai.Chat.talk(content: "refactor", mod: :function, model: :claude_opus, prompt: :coder, timeout: 60_000)

      # Multi-session isolation
      iex> Eai.Chat.talk(content: "analyze", chat_session: "research", pty_session_id: "isolated")

      # With chara card (overrides model + prompt)
      iex> Eai.Chat.talk(content: "code review", mod: :function, chara_card: :backend_engineer)

  ## Available Models, Prompts & Cards
      iex> Eai.Models.names()        # => [:deepseek, :claude_opus, :gpt4o, ...]
      iex> Eai.Prompts.names()       # => [:momoka, :coder, :analyst]
      iex> Eai.Card.names()          # => [:backend_engineer, :frontend_dev, ...]
  """
  def talk(opts \\ []) do
    timeout = Keyword.get(opts, :timeout, :infinity)
    mode = Keyword.get(opts, :mod, :human)
    content = Keyword.get(opts, :content)
    model_opt = Keyword.get(opts, :model)
    prompt_opt = Keyword.get(opts, :prompt)
    chara_card_opt = Keyword.get(opts, :chara_card)
    chat_session = opts |> Keyword.get(:chat_session, "default") |> to_string()
    pty_session = opts |> Keyword.get(:pty_session_id, chat_session) |> to_string()

    case {mode, content} do
      {m, nil} when m in [:h, :human] ->
        case GenServer.call(Eai.Naming.chat(), {:status, chat_session}) do
          :busy ->
            IO.puts(
              "A task is already running in session '#{chat_session}'. Please wait or interrupt it first."
            )

            {:error, :busy}

          _ ->
            IO.puts(
              "EAI Chat [#{chat_session}]. Type '/s' on a new line to send your message. Type '/c' on a new line to cancel"
            )

            read_lines(timeout, model_opt, prompt_opt, chara_card_opt, chat_session, pty_session, [])
            :ok
        end

      {m, msg} when not is_nil(msg) and m in [:f, :function, :h, :human] ->
        GenServer.call(
          Eai.Naming.chat(),
          {:talk, msg, timeout, model_opt, prompt_opt, chara_card_opt, chat_session, pty_session},
          :infinity
        )

      {m, _} ->
        IO.puts(
          "Invalid mod: #{inspect(m)}. Use :h/:human (interactive) or :f/:function (single-line with content)."
        )

        {:error, :invalid_mod}
    end
  end

  @doc """
  Get full message history for a chat session.

  ## Options
    * `chat_session` (string) — Session name. Default: `"default"`

  ## Returns
    List of `Eai.Message.t()` in conversation order.
  """
  def get_history(chat_session \\ "default") do
    GenServer.call(Eai.Naming.chat(), {:get_history, to_string(chat_session)})
  end

  @doc """
  Force interrupt current LLM task (async mode only).

  Sets interrupt flag; next task poll injects Ctrl+C to running PTY process.
  Only works in async `:human` mode (sync mode blocks IEx).

  ## Options
    * `chat_session` (string) — Session to interrupt. Default: `"default"`

  ## Example
      iex> Eai.Chat.interrupt!("work")
      :ok
  """
  def interrupt!(chat_session \\ "default") do
    GenServer.call(Eai.Naming.chat(), {:interrupt!, to_string(chat_session)})
  end

  @doc """
  Explicitly close a chat session and release its history.

  Cannot close `"default"` session.

  ## Options
    * `name` (string) — Session name to close.

  ## Example
      iex> Eai.Chat.close_chat_session("research")
      :ok
  """
  def close_chat_session(name) do
    GenServer.call(Eai.Naming.chat(), {:close_chat_session, to_string(name)})
  end

  @doc """
  List all active chat sessions with message count and status.

  ## Returns
      `[{session_name, message_count, status}, ...]`
      where status is `:idle` or `:busy`
  """
  def list_chat_sessions do
    GenServer.call(Eai.Naming.chat(), :list_chat_sessions)
  end

  @doc """
  Export chat session history to a gzip file.

  Called by LLM tool `export_context` or manually.

  ## Options
    * `file_path` (string) — Destination file path.
    * `chat_session` (string) — Session to export. Default: `"default"`

  ## Returns
      `{:ok, info}` or `{:error, reason}`

  ## Example
      iex> Eai.Chat.export_history("/tmp/session.gz", "work")
      {:ok, %{size_bytes: 5432, message_count: 42}}
  """
  def export_history(file_path, chat_session \\ "default") do
    GenServer.call(Eai.Naming.chat(), {:export_history, file_path, to_string(chat_session)})
  end

  @doc """
  Load chat history from a gzip file and replace session's messages.

  ## Options
    * `file_path` (string) — Source gzip file path.
    * `chat_session` (string) — Target session. Default: `"default"`
    * `format` (string) — Message format. Default: `"converse"`
      - `"converse"` — already in `Eai.Message` IR format
      - `"openai"` — needs OpenAI adapter conversion
      - `"anthropic"` — needs Anthropic adapter conversion

  ## Returns
      `{:ok, info}` or `{:error, reason}`

  ## Example
      iex> Eai.Chat.replace_history("/tmp/session.gz", "work_restored")
      {:ok, %{message_count: 42, chat_session: "work_restored"}}
  """
  def replace_history(file_path, chat_session \\ "default", format \\ "converse") do
    GenServer.call(
      Eai.Naming.chat(),
      {:replace_history, file_path, to_string(chat_session), format}
    )
  end

  # ── 私有：多行读取循环 ──────────────────────────────────────────

  defp read_lines(timeout, model_opt, prompt_opt, chara_card_opt, chat_session, pty_session, lines) do
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
            submit_or_restart(message, timeout, model_opt, prompt_opt, chara_card_opt, chat_session, pty_session)

          trimmed == "/c" ->
            IO.puts("Cancelled.")

          true ->
            read_lines(timeout, model_opt, prompt_opt, chara_card_opt, chat_session, pty_session, [
              trimmed | lines
            ])
        end
    end
  end

  defp submit_or_restart(message, timeout, model_opt, prompt_opt, chara_card_opt, chat_session, pty_session) do
    if String.trim(message) == "" do
      IO.puts("No message to send. Starting over.")
      read_lines(timeout, model_opt, prompt_opt, chara_card_opt, chat_session, pty_session, [])
    else
      GenServer.cast(
        Eai.Naming.chat(),
        {:talk_async, message, timeout, model_opt, prompt_opt, chara_card_opt, chat_session, pty_session}
      )

      IO.puts(~s|Task submitted. Use Eai.Chat.interrupt!("#{chat_session}") to cancel its current task, or Eai.Task.trigger_timeout_window("#{pty_session}") to stop the loop and nudge the model to wrap up.|)
    end
  end

  # ── 服务端回调 ───────────────────────────────────────────────────

  @impl true
  def init(_) do
    {:ok,
     %{
       sessions: %{"default" => new_session()},
       ref_to_session: %{}
     }}
  end

  @impl true
  def handle_call({:status, chat_session_id}, _from, state) do
    session = get_session(state, chat_session_id)
    {:reply, if(is_nil(session.task_ref), do: :idle, else: :busy), state}
  end

  @impl true
  def handle_call(
        {:talk, text, timeout, model_opt, prompt_opt, chara_card_opt, chat_session_id, pty_session_id},
        from,
        state
      ) do
    session = get_session(state, chat_session_id)

    if is_nil(session.task_ref) do
      sanitized = Utils.sanitize_value(text)
      user_msg = Message.new(:user, sanitized)
      new_messages = session.messages ++ [user_msg]
      run_opts = build_run_opts(model_opt, prompt_opt, chara_card_opt, chat_session_id)

      :telemetry.execute(
        [:eai, :chat, :session, :start],
        %{system_time: System.system_time()},
        %{chat_session_id: chat_session_id, pty_session_id: pty_session_id, msg_count: length(new_messages)}
      )

      task = Task.async(fn -> Direct.run(new_messages, pty_session_id, run_opts) end)
      Process.unlink(task.pid)

      remind_timer =
        if timeout != :infinity and is_integer(timeout) and timeout > 0 do
          Process.send_after(self(), {:remind_model, pty_session_id, chat_session_id}, timeout)
        end

      new_session = %{
        session
        | messages: new_messages,
          from: from,
          task_ref: task.ref,
          remind_timer: remind_timer
      }

      new_state =
        state |> put_session(chat_session_id, new_session) |> put_ref(task.ref, chat_session_id)

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
      TaskResult.set_interrupt_flag(chat_session_id)
      {:reply, :ok, state}
    end
  end

  @impl true
  def handle_call({:get_history, chat_session_id}, _from, state) do
    {:reply, get_session(state, chat_session_id).messages, state}
  end

  @impl true
  def handle_call(:list_chat_sessions, _from, state) do
    result =
      Map.new(state.sessions, fn {id, session} ->
        {id,
         %{
           message_count: length(session.messages),
           status: if(is_nil(session.task_ref), do: "idle", else: "busy")
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
        :telemetry.execute(
          [:eai, :chat, :session, :close],
          %{system_time: System.system_time()},
          %{chat_session_id: name}
        )
        {:reply, :ok, %{state | sessions: Map.delete(state.sessions, name)}}
    end
  end

  @impl true
  def handle_call({:export_history, file_path, chat_session_id}, _from, state) do
    session = get_session(state, chat_session_id)

    result =
      try do
        File.mkdir_p!(Path.dirname(file_path))
        sanitized = Utils.sanitize_messages(session.messages)
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
    result =
      try do
        compressed = File.read!(file_path)
        decompressed = :zlib.gunzip(compressed)
        raw = :erlang.binary_to_term(decompressed)
        messages = convert_imported_messages(raw, format)
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
  def handle_cast(
        {:talk_async, text, timeout, model_opt, prompt_opt, chara_card_opt, chat_session_id, pty_session_id},
        state
      ) do
    session = get_session(state, chat_session_id)
    sanitized = Utils.sanitize_value(text)
    user_msg = Message.new(:user, sanitized)
    new_messages = session.messages ++ [user_msg]
    run_opts = build_run_opts(model_opt, prompt_opt, chara_card_opt, chat_session_id)

    task = Task.async(fn -> Direct.run(new_messages, pty_session_id, run_opts) end)
    Process.unlink(task.pid)

    remind_timer =
      if timeout != :infinity and is_integer(timeout) and timeout > 0 do
        Process.send_after(self(), {:remind_model, pty_session_id, chat_session_id}, timeout)
      end

    new_session = %{
      session
      | messages: new_messages,
        task_ref: task.ref,
        remind_timer: remind_timer,
        from: nil
    }

    new_state =
      state |> put_session(chat_session_id, new_session) |> put_ref(task.ref, chat_session_id)

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

        {reply_to_caller, new_messages} =
          case result do
            {:ok, reply, full_history} ->
              IO.puts("\n🧙‍♀️ Assistant [##{chat_session_id}]: #{reply}")
              {{:ok, reply}, full_history}

            {:error, reason, partial_history} ->
              IO.puts("
❌ Error [#{chat_session_id}]: #{inspect(reason)}")
              {{:error, reason}, partial_history}
          end

        Phoenix.PubSub.broadcast(
          Eai.Naming.pubsub(),
          "chat_updates:#{chat_session_id}",
          {:new_message, new_messages}
        )

        if session.from, do: GenServer.reply(session.from, reply_to_caller)

        new_session = %{
          session
          | messages: new_messages,
            task_ref: nil,
            from: nil,
            remind_timer: nil
        }

        new_state =
          %{state | ref_to_session: new_ref_map}
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

        Phoenix.PubSub.broadcast(
          Eai.Naming.pubsub(),
          "chat_updates:#{chat_session_id}",
          {:new_message, session.messages}
        )

        IO.puts("
💥 Task crashed [#{chat_session_id}]: #{inspect(reason)}")
        if session.from, do: GenServer.reply(session.from, {:error, {:task_crashed, reason}})

        new_session = %{session | task_ref: nil, from: nil, remind_timer: nil}

        new_state =
          %{state | ref_to_session: new_ref_map}
          |> put_session(chat_session_id, new_session)

        {:noreply, new_state}
    end
  end

  # 超时提醒
  @impl true
  def handle_info({:remind_model, pty_session_id, chat_session_id}, state) do
    Logger.info(
      "Chat: timeout reached, triggering timeout window for pty=#{pty_session_id} chat=#{chat_session_id}"
    )

    TaskResult.trigger_timeout_window(pty_session_id)

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

  defp build_run_opts(model_opt, prompt_opt, chara_card_opt, chat_session_id) do
    card_opts = if chara_card_opt, do: Eai.Card.to_opts(Eai.Card.get!(chara_card_opt)), else: []

    %{chat_session_id: chat_session_id}
    |> then(fn m -> Map.merge(m, Map.new(card_opts)) end)
    |> then(fn m -> if model_opt, do: Map.put(m, :model, model_opt), else: m end)
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
