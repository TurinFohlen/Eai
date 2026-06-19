defmodule Eai.Chat do
  @moduledoc "Main conversation GenServer managing multi-session chat history and async LLM tasks."

  use GenServer
  require Logger
  alias Eai.Adapter.Anthropic, as: AdapterAnthropic
  alias Eai.Adapter.OpenAI, as: AdapterOpenAI
  alias Eai.Chat.Context
  alias Eai.LLM.Direct
  alias Eai.Message
  alias Eai.ResultCollector, as: TaskResult
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

    * `:temperature` (float | integer | nil) — Sampling temperature forwarded to the
      LLM provider as the `"temperature"` field in the HTTP body. Default: nil (provider default).
    * `:top_p` (float | nil) — Nucleus sampling cutoff (Anthropic / OpenAI / Bedrock
      `inferenceConfig.topP`). Default: nil (provider default).
    * `:top_k` (integer | nil) — Top-K sampling (Anthropic / Bedrock `inferenceConfig.topK`).
      OpenAI does NOT support — dropped at the OpenAI adapter. Default: nil (provider default).
    * `:min_p` (float | nil) — Min-P sampling. Reserved for future adapter support; no
      current adapter emits this field. Default: nil (provider default).
    * `:max_tokens` (integer | nil) — Maximum output tokens (Anthropic / OpenAI /
      Bedrock `inferenceConfig.maxTokens`). Default: nil (provider default).
    * `:repetition_penalty` (float | nil) — Repetition penalty. Reserved for future
      adapter support; no current adapter emits this field. Default: nil (provider default).
    * `:frequency_penalty` (float | nil) — OpenAI frequency penalty. Anthropic and
      Bedrock do NOT support — dropped at those adapters. Default: nil (provider default).
    * `:presence_penalty` (float | nil) — OpenAI presence penalty. Anthropic and
      Bedrock do NOT support — dropped at those adapters. Default: nil (provider default).
    * `:stop_sequences` (list of strings | nil) — Custom stop sequences (Anthropic
      `stop_sequences`, OpenAI `stop`, Bedrock `inferenceConfig.stopSequences`).
      Default: nil (provider default).
    * `:seed` (integer | nil) — Random seed for reproducibility (OpenAI; Bedrock
      `inferenceConfig.seed`). Anthropic does NOT support. Default: nil (provider default).
    * `:anthropic_beta` (list of strings | nil) — Optional list of Anthropic beta
      header strings to send (e.g. `["output-128k-2025-02-19"]`). When multiple
      are given, joined with ", " per Anthropic's convention. Default: nil
      (no beta header sent — provider's default cap applies). Currently consumed
      only by `:anthropic` provider calls; harmless on other providers (the
      adapter does not read the value).

  **Precedence (per field, all 10 sampler fields + `:anthropic_beta`):**
  `talk/1` explicit opt > `config/models/<name>.exs` value > nil/omit. Step 7
  stores the defaults in model config files (NOT in chara cards).

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

  ## Returns
    * `:function` mode — `{:ok, reply}` on success, `{:error, reason}` on failure.
      When the chat session is currently busy, returns
      `{:error, :busy, message}` (note the 3-tuple shape, unified with `:human` mode).
    * `:human` mode — `:ok` after the interactive session ends,
      or `{:error, :busy, message}` if the session is already busy.
    * `{:error, :invalid_mod}` for an unknown `:mod` value.
  """
  def talk(opts \\ []) do
    chat_session = opts |> Keyword.get(:chat_session, "default") |> to_string()

    ctx = %Context{
      timeout: Keyword.get(opts, :timeout, :infinity),
      chat_session: chat_session,
      pty_session: opts |> Keyword.get(:pty_session_id, chat_session) |> to_string(),
      model_opt: Keyword.get(opts, :model),
      prompt_opt: Keyword.get(opts, :prompt),
      chara_card_opt: Keyword.get(opts, :chara_card),
      temperature_opt: Keyword.get(opts, :temperature),
      top_p_opt: Keyword.get(opts, :top_p),
      top_k_opt: Keyword.get(opts, :top_k),
      min_p_opt: Keyword.get(opts, :min_p),
      max_tokens_opt: Keyword.get(opts, :max_tokens),
      repetition_penalty_opt: Keyword.get(opts, :repetition_penalty),
      frequency_penalty_opt: Keyword.get(opts, :frequency_penalty),
      presence_penalty_opt: Keyword.get(opts, :presence_penalty),
      stop_sequences_opt: Keyword.get(opts, :stop_sequences),
      seed_opt: Keyword.get(opts, :seed),
      anthropic_beta_opt: Keyword.get(opts, :anthropic_beta)
    }

    mode = Keyword.get(opts, :mod, :human)
    content = Keyword.get(opts, :content)

    case {mode, content} do
      {m, nil} when m in [:h, :human] ->
        case GenServer.call(Eai.Naming.chat(), {:status, ctx.chat_session}) do
          :busy ->
            msg =
              "A task is already running in session '#{ctx.chat_session}'. Please wait or interrupt it first."

            IO.puts(msg)
            {:error, :busy, msg}

          _ ->
            IO.puts(
              "EAI Chat [#{ctx.chat_session}]. Type '/s' on a new line to send your message. Type '/c' on a new line to cancel"
            )

            read_lines(ctx, [])
            :ok
        end

      {m, msg} when not is_nil(msg) and m in [:f, :function, :h, :human] ->
        GenServer.call(
          Eai.Naming.chat(),
          {:talk, msg, ctx},
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

  ## Returns
    `:ok` on success.
    `{:error, :cannot_close_default}` when closing the `"default"` session.
    `{:error, :not_found}` when the session does not exist.
    `{:error, :busy, message}` when a task is still running in the session.

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
  Ensure a chat session exists in `state.sessions`. If the session
  already exists, this is a no-op (returns `:ok` and state is
  unchanged). If the session does NOT exist, an empty session is
  materialized in `state.sessions` and `:ok` is returned.

  This is used by `Eai.System.restore_from_gzip/1` to PRE-CREATE every
  session in the snapshot before writing any messages, so that
  `Eai.Chat.list_chat_sessions/0` sees the full set of sessions
  during the restore window. Without this pre-create, sessions
  appear one-by-one as `replace_history/3` is called, and a
  concurrent observer could see an inconsistent state.

  ## Options
    * `chat_session` (string) — Session name. Default: `"default"`.

  ## Returns
    `:ok`
  """
  def ensure_session_exists(chat_session \\ "default") do
    GenServer.call(Eai.Naming.chat(), {:ensure_session, to_string(chat_session)})
  end

  @doc """
  Export chat session history to a gzip file.

  Called by LLM tool `export_chat_session_context` or manually.

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

  defp read_lines(%Context{} = ctx, lines) do
    case IO.gets("> ") do
      :eof ->
        IO.puts("Cancelled.")

      {:error, reason} ->
        IO.puts("Error: #{inspect(reason)}")

      line ->
        trimmed = String.trim(line)

        cond do
          trimmed == "/s" ->
            submit_or_restart(%{ctx | message: Enum.join(Enum.reverse(lines), "\n")})

          trimmed == "/c" ->
            IO.puts("Cancelled.")

          true ->
            read_lines(ctx, [trimmed | lines])
        end
    end
  end

  defp submit_or_restart(%Context{} = ctx) do
    if String.trim(ctx.message) == "" do
      IO.puts("No message to send. Starting over.")
      read_lines(ctx, [])
    else
      GenServer.cast(
        Eai.Naming.chat(),
        {:talk_async, ctx}
      )

      IO.puts(
        ~s|Task submitted. Use Eai.Chat.interrupt!("#{ctx.chat_session}") to cancel its current task, or Eai.ResultCollector.trigger_timeout_window("#{ctx.pty_session}") to stop the loop and nudge the model to wrap up.|
      )
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
  def handle_call({:ensure_session, chat_session_id}, _from, state) do
    case Map.fetch(state.sessions, chat_session_id) do
      {:ok, _session} ->
        {:reply, :ok, state}

      :error ->
        {:reply, :ok, put_session(state, chat_session_id, new_session())}
    end
  end

  @impl true
  def handle_call(
        {:talk, text, %Context{} = ctx},
        from,
        state
      ) do
    session = get_session(state, ctx.chat_session)

    if is_nil(session.task_ref) do
      sanitized = Utils.sanitize_value(text)
      user_msg = Message.new(:user, sanitized)
      new_messages = session.messages ++ [user_msg]

      run_opts = build_run_opts(ctx)

      :telemetry.execute(
        [:eai, :chat, :session, :start],
        %{system_time: System.system_time()},
        %{
          chat_session_id: ctx.chat_session,
          pty_session_id: ctx.pty_session,
          msg_count: length(new_messages)
        }
      )

      task =
        Task.Supervisor.async_nolink(
          Eai.Naming.task_supervisor(),
          fn -> Direct.run(new_messages, ctx.pty_session, run_opts) end
        )

      remind_timer =
        if ctx.timeout != :infinity and is_integer(ctx.timeout) and ctx.timeout > 0 do
          Process.send_after(
            self(),
            {:remind_model, ctx.pty_session, ctx.chat_session},
            ctx.timeout
          )
        end

      new_session = %{
        session
        | messages: new_messages,
          from: from,
          task_ref: task.ref,
          remind_timer: remind_timer
      }

      new_state =
        state |> put_session(ctx.chat_session, new_session) |> put_ref(task.ref, ctx.chat_session)

      {:noreply, new_state}
    else
      {:reply, {:error, :busy, "Another task is running in session '#{ctx.chat_session}'."},
       state}
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
        {:reply,
         {:error, :busy, "Cannot close session '#{name}': a task is still running in it."}, state}

      {:ok, _session} ->
        :telemetry.execute(
          [:eai, :chat, :session, :close],
          %{system_time: System.system_time()},
          %{chat_session_id: name}
        )

        # Step 2: cascade-clean any subagent entries that are queued for
        # this session. Without this, an LLM polling a queued subagent
        # after the session is closed would get a permanently `pending`
        # status (the dequeue trigger — finishing a subagent task — will
        # never fire for a closed session).
        #
        # We snapshot the queue first, fail every entry, then drop the
        # queue key. Wrapped in `transaction/2` with `queue_key` as the
        # lock target so a concurrent dequeue call (from a sibling task
        # finishing in the same millisecond) cannot pop a task that is
        # about to be cancelled. Each per-task result overwrite is a
        # separate `cache.put` so a single bad entry can't poison the
        # whole batch.
        cascade_close_queue(name)

        # Step 3 fix: also drop any ref_to_session entries that point at
        # the closed session. Without this, a late-arriving DOWN message
        # would re-enter the handle_info body, call put_session to
        # resurrect the session in state.sessions, and trigger a
        # dequeue — resurrecting a session the user just closed. We
        # also notify any still-pending monitors that the ref is gone.
        new_ref_to_session =
          state.ref_to_session
          |> Enum.reject(fn {_ref, sid} -> sid == name end)
          |> Map.new()

        {:reply, :ok,
         %{state | sessions: Map.delete(state.sessions, name), ref_to_session: new_ref_to_session}}
    end
  end

  @impl true
  def handle_call({:export_history, file_path, chat_session_id}, _from, state) do
    session = get_session(state, chat_session_id)

    result =
      try do
        compressed = snapshot_messages_bytes_from(session.messages)
        File.mkdir_p!(Path.dirname(file_path))
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

  # Step 4 — public helper extracted from the original export_history
  # handle_call body so Eai.System.snapshot_to_gzip/1 can reuse the
  # exact same format. Returns the gzip blob directly (no wrapper tuple).
  #
  # Reads messages live from the GenServer (one GenServer.call). The
  # caller (Eai.System) is responsible for await_idle/1 first to avoid
  # racing with in-flight mutations.
  def snapshot_messages_bytes(chat_session_id) do
    chat_session_id
    |> get_history()
    |> snapshot_messages_bytes_from()
  end

  defp snapshot_messages_bytes_from(messages) do
    messages
    |> Utils.sanitize_messages()
    |> :erlang.term_to_binary()
    |> :zlib.gzip()
  end

  @impl true
  def handle_cast({:talk_async, %Context{} = ctx}, state) do
    session = get_session(state, ctx.chat_session)
    sanitized = Utils.sanitize_value(ctx.message)
    user_msg = Message.new(:user, sanitized)
    new_messages = session.messages ++ [user_msg]

    run_opts = build_run_opts(ctx)

    task =
      Task.Supervisor.async_nolink(
        Eai.Naming.task_supervisor(),
        fn -> Direct.run(new_messages, ctx.pty_session, run_opts) end
      )

    remind_timer =
      if ctx.timeout != :infinity and is_integer(ctx.timeout) and ctx.timeout > 0 do
        Process.send_after(
          self(),
          {:remind_model, ctx.pty_session, ctx.chat_session},
          ctx.timeout
        )
      end

    new_session = %{
      session
      | messages: new_messages,
        task_ref: task.ref,
        remind_timer: remind_timer,
        from: nil
    }

    new_state =
      state |> put_session(ctx.chat_session, new_session) |> put_ref(task.ref, ctx.chat_session)

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

        # Step 3: trigger dequeue from the chat GenServer AFTER task_ref
        # has been cleared. Mailbox ordering guarantees the dequeue's
        # spawned Task sees the now-idle session, closing the
        # microsecond race documented in step2_changes.md §F.
        # credo:disable-for-next-line
        apply(Eai.Tool.CallSubagent, :dequeue_next_subagent, [chat_session_id])

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

        # Step 3: same as the {ref, result} branch — trigger dequeue from
        # the chat GenServer after task_ref is cleared.
        # credo:disable-for-next-line
        apply(Eai.Tool.CallSubagent, :dequeue_next_subagent, [chat_session_id])

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

  defp build_run_opts(%Context{} = ctx) do
    card_opts =
      if ctx.chara_card_opt, do: Eai.Card.to_opts(Eai.Card.get!(ctx.chara_card_opt)), else: []

    # Build optional fields dynamically using omit-when-nil pattern.
    # Fields present in the map are forwarded to Direct.run/3 as overrides;
    # absent fields fall back to the model config (config/models/<name>.exs),
    # and if absent there too they are omitted from the HTTP body.
    optional = [
      model: ctx.model_opt,
      system_prompt: ctx.prompt_opt,
      temperature: ctx.temperature_opt,
      top_p: ctx.top_p_opt,
      top_k: ctx.top_k_opt,
      min_p: ctx.min_p_opt,
      max_tokens: ctx.max_tokens_opt,
      repetition_penalty: ctx.repetition_penalty_opt,
      frequency_penalty: ctx.frequency_penalty_opt,
      presence_penalty: ctx.presence_penalty_opt,
      stop_sequences: ctx.stop_sequences_opt,
      seed: ctx.seed_opt,
      anthropic_beta: ctx.anthropic_beta_opt
    ]

    %{chat_session_id: ctx.chat_session}
    |> Map.merge(Map.new(card_opts))
    |> Map.merge(Map.new(Enum.reject(optional, fn {_k, v} -> is_nil(v) end)))
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

  defp cascade_close_queue(chat_session_id) do
    cache = Eai.Naming.cache()
    queue_key = "session_queue:#{chat_session_id}"

    close_opts = [keys: [queue_key]]

    case cache.transaction(
           close_opts,
           fn ->
             queue = cache.get(queue_key) || []
             cache.delete(queue_key)
             queue
           end
         ) do
      [] ->
        :ok

      queue when is_list(queue) ->
        Enum.each(queue, fn entry ->
          {task_id, pty_session_id} = extract_queue_error_fields(entry)

          cache.put("subagent_result:#{task_id}", %{
            status: "error",
            reason: "session_closed",
            chat_session: chat_session_id,
            pty_session_id: pty_session_id
          })
        end)

        :ok

      _ ->
        :ok
    end
  end

  defp extract_queue_error_fields(%{task_id: tid, pty_session_id: pid}), do: {tid, pid}
  defp extract_queue_error_fields(_), do: {nil, nil}
end
