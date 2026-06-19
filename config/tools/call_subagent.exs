defmodule Eai.Tool.CallSubagent do
  @moduledoc """
  子代理派发工具。支持会话复用和前缀缓存。
  - 首次调用时创建独立 chat session，可通过 pre_context 加载历史前缀。
  - 后续通过 chat_session 参数追加消息，复用同一会话历史。
  - 子代理完成后不自动关闭，需显式调用 close_chat_session 或等待系统回收。
  """

  @behaviour Eai.Tool
  require Logger

  @impl true
  def schema do
    %{
      type: "function",
      function: %{
        name: "call_subagent",
        description: """
        Dispatch a sub-task to a fresh, independent AI agent with minimal context.
        The subagent starts with ONLY its system prompt + your message — it does NOT
        inherit the main conversation history. This makes subagent tool calls ~50× cheaper
        per round-trip than running the same task in the main context.

        **When to use:** Context-independent work (compilation, file ops, research,
        benchmarks). Any task you can describe in one sentence without referencing
        "what we discussed earlier" is a good candidate.

        **When NOT to use:** Trivial one-liners (echo, pwd) — spawn overhead > savings.
        Tasks that need conversation context ("continue what I was doing").

        Supports session reuse via `chat_session`, prefix caching via `pre_context`,
        and prompt/model selection. Use `close_chat_session` when done.
        Poll results with `get_subagent_result` (same poll_cooldown_ms cost model).

        **Return shape & queueing:** The call ALWAYS returns a `subagent_task_id`
        immediately, with the synchronous status `queued` meaning "we accepted your
        request, the task_id is live". If the target chat_session is currently busy
        with another task, the subagent is **enqueued** (internal status `pending`)
        and will dispatch automatically when the in-flight task finishes. Poll
        `get_subagent_result` to see the actual progress: `pending` (waiting for a
        free slot) → `running` → `complete` | `error`.
        """,
        parameters: %{
          type: "object",
          properties: %{
            message: %{
              type: "string",
              description: "The task instruction or question for the sub-agent."
            },
            chat_session: %{
              type: "string",
              description:
                "Optional. Reuse an existing sub-agent session. If not given, a new session is created."
            },
            pre_context: %{
              type: "string",
              description: """
              Optional. Path to an exported history .gzip file to load ONCE when creating a new session.
              Ignored if the session already exists.
              Enables LLM prefix caching when the same history is reused across calls.
              """
            },
            format: %{
              type: "string",
              description:
                "Format of the pre_context file ('converse', 'openai', 'anthropic'). Default 'converse'."
            },
            pty_session_id: %{
              type: "string",
              description:
                "Optional. PTY session for shell isolation. Defaults to the chat_session ID."
            },
            model: %{
              type: "string",
              description: "Optional model name (e.g., 'gpt4o', 'claude_sonnet', 'deepseek')."
            },
            prompt: %{
              type: "string",
              description: "Optional system prompt name (e.g., 'coder', 'analyst')."
            },
            sbc: %{
              type: "boolean",
              description:
                "If true, blocks until subagent completes and returns result directly (saves 2+ roundtrips). Default: false. Use for tasks expected to finish quickly (<60s). DO NOT use for tasks that might hang."
            },
            temperature: %{
              type: ["number", "null"],
              description:
                "Optional. Sampling temperature forwarded to the LLM (Anthropic / OpenAI / Bedrock). Default nil (provider default)."
            }
          },
          required: ["message"]
        }
      }
    }
  end

  @impl true
  def execute(args, _pty_session_id, _chat_session_id) do
    message = Map.get(args, "message", "")
    model_opt = args |> Map.get("model") |> maybe_atom()
    prompt_opt = args |> Map.get("prompt") |> maybe_atom()
    temperature_opt = Map.get(args, "temperature")

    pre_context_path = Map.get(args, "pre_context")
    format_opt = Map.get(args, "format", "converse")

    existing_session = Map.get(args, "chat_session")

    chat_session_id =
      existing_session || "subagent_#{System.unique_integer([:positive, :monotonic])}"

    pty_session_id = Map.get(args, "pty_session_id", chat_session_id)

    sbc_raw = Map.get(args, "sbc", false)
    sbc? = sbc_raw == true or sbc_raw == "true"

    # ── pre_context loading (shared by both modes) ──────────────
    if is_nil(existing_session) && pre_context_path && File.exists?(pre_context_path) do
      case Eai.Chat.replace_history(pre_context_path, chat_session_id, format_opt) do
        {:ok, count} ->
          Logger.info("Subagent pre_context loaded: #{count} messages from #{pre_context_path}")

        {:error, reason} ->
          Logger.error("Subagent pre_context load failed: #{reason}")
      end
    end

    if sbc? do
      # ── SBC mode (same pattern as execute_script sbc) ──
      sbc_result(chat_session_id, pty_session_id, message, model_opt, prompt_opt, temperature_opt)
    else
      # ── async mode (original behaviour) ────────────────────────
      async_dispatch(
        chat_session_id,
        pty_session_id,
        message,
        model_opt,
        prompt_opt,
        temperature_opt
      )
    end
  end

  # ── Shared: dispatch subagent Task, return task_id ──────────
  # Both SBC and async modes use the same dispatch path.
  # SBC then polls internally; async returns the task_id for the
  # LLM to poll via get_subagent_result.
  #
  # Step 2: when the target chat session is busy, the subagent is
  # *enqueued* (status: "pending") rather than failing. The dequeue
  # happens at the end of every successful dispatch via
  # `dequeue_next_subagent/5`.
  #
  # Queue entries are maps carrying all subagent fields; enqueued entries
  # are dispatched automatically when the session becomes idle. Legacy
  # tuple entries from pre-refactor crashes are not supported — they
  # will hit the :unknown branch in dequeue_next_subagent and be dropped.

  defp dispatch_subagent(
         chat_session_id,
         pty_session_id,
         message,
         model_opt,
         prompt_opt,
         temperature_opt
       ) do
    subagent_task_id = "satask_#{System.unique_integer([:positive, :monotonic])}"
    now = System.monotonic_time(:millisecond)
    cache = Eai.Naming.cache()
    queue_key = "session_queue:#{chat_session_id}"
    result_key = "subagent_result:#{subagent_task_id}"

    # Read current chat-session status + enqueue or dispatch atomically.
    # Wrapping in `transaction/2` with the queue key as the lock target
    # means two concurrent calls for the same chat_session cannot both
    # see `:idle` and both spawn tasks. The Local adapter's transaction
    # lock is acquired on `queue_key`; a different chat_session can
    # proceed in parallel because its lock is on a different key.
    #
    # We re-fetch status *inside* the transaction (instead of trusting
    # the value from a prior `Eai.Chat.status/1` call) to avoid a TOCTOU
    # race: a subagent for the same session could finish between the
    # status read and the enqueue.
    #
    # The transaction opts are bound to a local variable instead of being
    # written inline as `keys: [queue_key]`. Inlining the keyword list
    # next to the anonymous fn confuses some type-inference passes (Elixir
    # 1.20 / dialyzer) into reading the `fn` as the second positional
    # argument, which then surfaces as a runtime `Keyword.get/3` failure
    # inside the Nebulex Local adapter's lock acquisition path. Binding
    # `tx_opts` to a clearly-typed keyword list removes that ambiguity.
    tx_opts = [keys: [queue_key]]

    tx_result =
      cache.transaction(
        tx_opts,
        fn ->
          case GenServer.call(Eai.Naming.chat(), {:status, chat_session_id}) do
            :busy ->
              # Enqueue: write a pending cache entry + append to queue.
              cache.put(result_key, %{
                status: "pending",
                queued_at: now,
                chat_session: chat_session_id
              })

              entry = %{
                task_id: subagent_task_id,
                message: message,
                pty_session_id: pty_session_id,
                model_opt: model_opt,
                prompt_opt: prompt_opt,
                temperature_opt: temperature_opt
              }

              queue = cache.get(queue_key) || []
              cache.put(queue_key, queue ++ [entry])

              {:enqueued, subagent_task_id}

            _ ->
              # Idle: write a running entry and dispatch immediately.
              cache.put(result_key, %{
                status: "running",
                started_at: now,
                chat_session: chat_session_id
              })

              {:dispatched, subagent_task_id}
          end
        end
      )

    case tx_result do
      {:enqueued, _} ->
        # Don't spawn a Task — the dequeue in a sibling dispatch
        # (or this one, if the other task finishes first) will pick
        # us up. The cache already has the "pending" entry; the LLM
        # can poll get_subagent_result immediately.
        :ok

      {:dispatched, _} ->
        entry = %{
          task_id: subagent_task_id,
          message: message,
          pty_session_id: pty_session_id,
          model_opt: model_opt,
          prompt_opt: prompt_opt,
          temperature_opt: temperature_opt
        }

        spawn_dispatch_task(entry, chat_session_id)
    end

    subagent_task_id
  end

  # ── Spawn the supervised subagent task (called from dispatch or dequeue) ─

  defp spawn_dispatch_task(%{} = entry, chat_session_id) do
    %{
      task_id: subagent_task_id,
      message: message,
      pty_session_id: pty_session_id,
      model_opt: model_opt,
      prompt_opt: prompt_opt,
      temperature_opt: temperature_opt
    } = entry

    # Use Task.Supervisor.async_nolink so the subagent task is owned by the
    # supervisor rather than leaking as a free linked process. If the task
    # crashes, the supervisor logs the error and the VM stays up. We don't
    # need the task struct back — the cache write is the completion signal
    # that get_subagent_result / sbc_wait poll on.
    #
    # Note: `Task.Supervisor.async_nolink/2` returns the `%Task{}` struct
    # directly (not `{:ok, task}` — that's `Task.Supervisor.start_child/2`).
    # Binding the struct to a `_task` underscore makes it explicit we don't
    # need it and silences the "this match will never succeed" warning.
    _task =
      Task.Supervisor.async_nolink(Eai.Naming.task_supervisor(), fn ->
        result_entry =
          try do
            case Eai.Chat.talk(
                   content: message,
                   mod: :f,
                   chat_session: chat_session_id,
                   pty_session_id: pty_session_id,
                   model: model_opt,
                   prompt: prompt_opt,
                   temperature: temperature_opt,
                   timeout: 120_000
                 ) do
              {:ok, response} ->
                %{status: "complete", answer: response, pty_session_id: pty_session_id}

              # Busy 3-tuple from Eai.Chat.talk/1. The dispatch path already
              # gated on `:status == :idle` inside a transaction, so under
              # normal operation we should not see this here. If we do (e.g.
              # a task landed on the same session in the millisecond after
              # the transaction released its lock), surface as an error.
              {:error, :busy, busy_msg} ->
                %{
                  status: "error",
                  reason: "busy: #{busy_msg}",
                  pty_session_id: pty_session_id
                }

              {:error, reason} ->
                %{status: "error", reason: inspect(reason), pty_session_id: pty_session_id}
            end
          rescue
            e ->
              Logger.error("Subagent task #{subagent_task_id} crashed: #{Exception.message(e)}")
              %{status: "error", reason: Exception.message(e), pty_session_id: pty_session_id}
          end

        # Step 2: finalise the result entry AND try to dequeue the next
        # pending subagent for this chat_session. Both are wrapped in a
        # top-level try/rescue so a thrown exception in either doesn't
        # leave the queue head stuck (e.g. a `:throw` from Eai.Chat.talk
        # that wasn't a `raise`, or a transient cache error). If both
        # fail, the cache entry defaults to status: "error" so the LLM
        # is at least informed; a stuck pending queue can be detected
        # and cleaned up by the stale-detection branch on the next poll.
        #
        # Step 3: the dequeue call is removed from the supervised task
        # body. The dequeue must run *after* `Eai.Chat`'s GenServer has
        # processed the `{ref, result}` / `{:DOWN, ...}` message and
        # cleared `task_ref` — otherwise the spawned Task hits the
        # `{:talk, ...}` busy guard and the dequeued subagent is
        # silently lost with `error: "busy: ..."`. The dequeue is now
        # invoked from `Eai.Chat.handle_info/2` (after `task_ref` is
        # cleared); mailbox ordering guarantees the chat GenServer is
        # ready to accept a new `{:talk, ...}` call by the time the
        # dequeue's spawned Task reaches `Eai.Chat.talk/1`. The
        # `cache.put` for the result_entry is unchanged.
        try do
          Eai.Naming.cache().put("subagent_result:#{subagent_task_id}", result_entry)
        rescue
          e ->
            Logger.error(
              "Subagent task #{subagent_task_id} cache.put failed: #{Exception.message(e)}"
            )

            Eai.Naming.cache().put("subagent_result:#{subagent_task_id}", %{
              status: "error",
              reason: "cache_put_failed: #{Exception.message(e)}",
              pty_session_id: pty_session_id
            })
        end
      end)
  end

  # ── Dequeue: pop one pending task for a session and dispatch it ─
  # Called at the end of every successful (or failed) subagent dispatch
  # so the next pending subagent can start as soon as the previous one
  # finishes. The read-pop-write is wrapped in `transaction/2` with
  # `queue_key` as the lock target so two dequeue callers cannot both
  # pick the same head.
  #
  # Caveat documented in step2_changes.md §F: this dequeue runs in the
  # supervised task body, *before* `Eai.Chat`'s GenServer has processed
  # the {ref, result} message for the task that just finished. There
  # is therefore a small race window where the cache says "task done"
  # but the GenServer still reports `:busy`. If the spawned Task
  # observes the busy guard, the LLM sees `status: "error", reason:
  # "busy: ..."` for a request the user *thought* was queued safely.
  # In practice this window is microseconds, but the explicit fix
  # (move the dequeue to `Eai.Chat.handle_info/2`) is deferred to a
  # follow-up step.
  #
  # Step 3: the dequeue is now invoked from `Eai.Chat.handle_info/2`
  # (after `task_ref` is cleared) rather than from the supervised task
  # body. Mailbox ordering in the chat GenServer guarantees
  # `{ref, result}` / `{:DOWN, ...}` is processed *before* the dequeue's
  # spawned Task can hit the `{:talk, ...}` busy guard, so the head of
  # the queue always sees `:idle` and dispatches cleanly. The function
  # signature is unchanged (still `chat_session_id -> :ok`); only the
  # visibility changed (`defp` → `def`) so `Eai.Chat` can call it.
  def dequeue_next_subagent(chat_session_id) do
    cache = Eai.Naming.cache()
    queue_key = "session_queue:#{chat_session_id}"
    now = System.monotonic_time(:millisecond)

    # Same rationale as `dispatch_subagent/6`: bind the transaction opts
    # to a local variable so the anonymous fn and the keyword list cannot
    # be confused at the call boundary (Elixir 1.20 / dialyzer).
    dequeue_opts = [keys: [queue_key]]

    dequeued =
      cache.transaction(
        dequeue_opts,
        fn ->
          queue = cache.get(queue_key) || []

          case queue do
            [] ->
              :empty

            [%{task_id: task_id} = entry | rest] ->
              cache.put("subagent_result:#{task_id}", %{
                status: "running",
                started_at: now,
                chat_session: chat_session_id
              })

              cache.put(queue_key, rest)
              {task_id, entry}

            # Defensive: an unrecognized queue head shape. Log and bail
            # rather than spinning on a stuck queue.
            [unknown | _] ->
              Logger.warning(
                "dequeue_next_subagent: unrecognized queue head shape: #{inspect(unknown)}; dropping"
              )

              :unknown
          end
        end
      )

    case dequeued do
      :empty ->
        :ok

      :unknown ->
        :ok

      {_task_id, entry} ->
        spawn_dispatch_task(entry, chat_session_id)
        :ok
    end
  end

  # ── SBC: dispatch async + internal polling loop ──────────────
  # Same pattern as execute_script sbc_wait: submit async,
  # then poll the result store (cache) until complete or timeout.
  # The LLM never sees the intermediate "running" states — they
  # never enter conversation history.

  defp sbc_result(
         chat_session_id,
         pty_session_id,
         message,
         model_opt,
         prompt_opt,
         temperature_opt
       ) do
    subagent_task_id =
      dispatch_subagent(
        chat_session_id,
        pty_session_id,
        message,
        model_opt,
        prompt_opt,
        temperature_opt
      )

    sbc_wait(subagent_task_id, chat_session_id, 60)
  end

  defp sbc_wait(subagent_task_id, chat_session_id, max_loops) do
    cooldown = Application.get_env(:eai, :poll_cooldown_ms) || 2000
    Process.sleep(cooldown)

    case Eai.Naming.cache().get("subagent_result:#{subagent_task_id}") do
      %{status: "complete", answer: answer} ->
        %{status: "complete", answer: answer, chat_session: chat_session_id}
        |> Eai.Utils.sanitize_value()
        |> Jason.encode!()

      %{status: "error", reason: reason} ->
        %{status: "error", reason: reason, chat_session: chat_session_id}
        |> Jason.encode!()

      _ when max_loops <= 0 ->
        Logger.warning("SBC timeout for subagent #{chat_session_id}")

        %{
          status: "timeout",
          reason: "subagent did not complete in time",
          chat_session: chat_session_id
        }
        |> Eai.Utils.sanitize_value()
        |> Jason.encode!()

      _ ->
        sbc_wait(subagent_task_id, chat_session_id, max_loops - 1)
    end
  end

  # ── Async: dispatch + return task_id immediately ─────────────
  defp async_dispatch(
         chat_session_id,
         pty_session_id,
         message,
         model_opt,
         prompt_opt,
         temperature_opt
       ) do
    subagent_task_id =
      dispatch_subagent(
        chat_session_id,
        pty_session_id,
        message,
        model_opt,
        prompt_opt,
        temperature_opt
      )

    %{
      subagent_task_id: subagent_task_id,
      chat_session: chat_session_id,
      status: "queued",
      pty_session_id: pty_session_id
    }
    |> Eai.Utils.sanitize_value()
    |> Jason.encode!()
  end

  defp maybe_atom(nil), do: nil
  defp maybe_atom(s), do: String.to_atom(s)
end
