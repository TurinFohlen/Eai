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
              description: "If true, blocks until subagent completes and returns result directly (saves 2+ roundtrips). Default: false. Use for tasks expected to finish quickly (<60s). DO NOT use for tasks that might hang."
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
          Logger.info(
            "Subagent pre_context loaded: #{count} messages from #{pre_context_path}"
          )

        {:error, reason} ->
          Logger.error("Subagent pre_context load failed: #{reason}")
      end
    end

    if sbc? do
      # ── SBC mode (same pattern as execute_script sbc) ──
      sbc_result(chat_session_id, pty_session_id, message, model_opt, prompt_opt)
    else
      # ── async mode (original behaviour) ────────────────────────
      async_dispatch(chat_session_id, pty_session_id, message, model_opt, prompt_opt)
    end
  end

  # ── Shared: dispatch subagent Task, return task_id ──────────
  # Both SBC and async modes use the same dispatch path.
  # SBC then polls internally; async returns the task_id for the
  # LLM to poll via get_subagent_result.

  defp dispatch_subagent(chat_session_id, pty_session_id, message, model_opt, prompt_opt) do
    subagent_task_id = "satask_#{System.unique_integer([:positive, :monotonic])}"

    Eai.Naming.cache().put("subagent_result:#{subagent_task_id}", %{
      status: "running",
      started_at: System.monotonic_time(:millisecond)
    })

    Task.start(fn ->
      result_entry =
        try do
          case Eai.Chat.talk(
                 content: message,
                 mod: :f,
                 chat_session: chat_session_id,
                 pty_session_id: pty_session_id,
                 model: model_opt,
                 prompt: prompt_opt,
                 timeout: 120_000
               ) do
            {:ok, response} ->
              %{status: "complete", answer: response, pty_session_id: pty_session_id}

            {:error, reason} ->
              %{status: "error", reason: inspect(reason), pty_session_id: pty_session_id}
          end
        rescue
          e ->
            Logger.error("Subagent task #{subagent_task_id} crashed: #{Exception.message(e)}")
            %{status: "error", reason: Exception.message(e), pty_session_id: pty_session_id}
        end

      Eai.Naming.cache().put("subagent_result:#{subagent_task_id}", result_entry)
    end)

    subagent_task_id
  end

  # ── SBC: dispatch async + internal polling loop ──────────────
  # Same pattern as execute_script sbc_wait: submit async,
  # then poll the result store (cache) until complete or timeout.
  # The LLM never sees the intermediate "running" states — they
  # never enter conversation history.

  defp sbc_result(chat_session_id, pty_session_id, message, model_opt, prompt_opt) do
    subagent_task_id = dispatch_subagent(
      chat_session_id, pty_session_id, message, model_opt, prompt_opt
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
        %{status: "timeout", reason: "subagent did not complete in time", chat_session: chat_session_id}
        |> Eai.Utils.sanitize_value()
        |> Jason.encode!()

      _ ->
        sbc_wait(subagent_task_id, chat_session_id, max_loops - 1)
    end
  end

  # ── Async: dispatch + return task_id immediately ─────────────
  defp async_dispatch(chat_session_id, pty_session_id, message, model_opt, prompt_opt) do
    subagent_task_id = dispatch_subagent(
      chat_session_id, pty_session_id, message, model_opt, prompt_opt
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
