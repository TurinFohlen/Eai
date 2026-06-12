defmodule Eai.LLM.Direct do
  @moduledoc """
  Direct LLM API orchestration using Converse-based internal message IR.

  All internal history is [Eai.Message.t()]. Before sending to an LLM provider,
  the appropriate adapter converts messages to provider-specific wire format.
  Responses are parsed back into Eai.Message.t().
  """
  @tools_dir Path.expand("config/tools", File.cwd!())

  alias Eai.Message

  # ── Tool registry (lazy-loaded on first run) ─────────────────────────

  defp load_tools do
    {:ok, files} = File.ls(@tools_dir)

    modules =
      files
      |> Enum.filter(&String.ends_with?(&1, ".exs"))
      |> Enum.sort()
      |> Enum.flat_map(fn file ->
        path = Path.join(@tools_dir, file)

        case Code.compile_file(path) do
          [{mod, _}] -> [mod]
          _ -> []
        end
      end)

    schemas = Enum.map(modules, & &1.schema())
    dispatch = Map.new(modules, fn mod -> {mod.schema().function.name, mod} end)
    registry = %{schemas: schemas, dispatch: dispatch}

    :persistent_term.put(:eai_llm_tools, registry)
    registry
  end

  defp tools do
    case :persistent_term.get(:eai_llm_tools, :not_found) do
      :not_found -> load_tools()
      registry -> registry
    end
  end

  # ── Public API ───────────────────────────────────────────────────────

  @doc """
  Run LLM tool-calling loop with messages.

  Internal API called by `Chat.talk/1`. Handles model selection, adapter routing,
  tool execution, and result polling.

  ## Options (map)

    * `:model` (atom) — Model name: `:deepseek`, `:claude_opus`, etc.
                        Default: from config `:default_model`
    * `:prompt` (atom) — System prompt: `:momoka`, `:coder`, `:analyst`, etc.
                         Default: `:momoka`
    * `:chat_session_id` (string) — Session for multi-session isolation.
                                     Default: `"default"`
    * `:card_system_prompt` (string) — Extra system prompt (role layer, appended).
                                        Default: nil
    * `:card_tools` (list) — Allowlist of tool names. Default: all tools
    * `:card_pre_context` (list) — Pre-loaded messages (for prefix caching).
                                    Default: nil

  **Internal fields** (filled automatically by `Chat.talk`, do NOT set externally):
    * `:provider` — Adapter provider (`:anthropic`, `:openai_compat`, etc.)
    * `:api_key` — LLM API key (from env)
    * `:url` — LLM endpoint URL
    * `:receive_timeout` — HTTP timeout in ms
    * `:reasoning_effort` — Model-specific (e.g., "high" for DeepSeek)
    * `:model_str` — Actual model string for API

  ## Returns
      `{:ok, final_reply}` or `{:error, reason}`

  ## Example (internal, called by Chat.talk)
      iex> Eai.LLM.Direct.run(
        messages,
        "default",
        %{model: :deepseek, prompt: :coder, chat_session_id: "work"}
      )
      {:ok, "Here's the refactored code..."}
  """
  def run(messages, pty_session_id \\ "default", opts \\ %{}) do
    entry = resolve_model_entry(opts)
    chat_session_id = Map.get(opts, :chat_session_id, "default") |> to_string()
    provider = Map.get(opts, :provider, entry[:provider] || :openai_compat)
    adapter = adapter_for(provider)

    api_key = Map.get(opts, :api_key, Eai.Models.api_key(entry))
    model = Map.get(opts, :model_str, entry[:model])
    url = Map.get(opts, :url, entry[:url])
    timeout = Map.get(opts, :receive_timeout, entry[:receive_timeout] || 120_000)
    effort = Map.get(opts, :reasoning_effort, entry[:reasoning_effort])
    prompt = resolve_prompt(Map.get(opts, :system_prompt))

    {messages, prompt, schemas, opts} = prepare_run_context(messages, prompt, opts)

    adapter_opts = [reasoning_effort: effort]
    req = adapter.to_request_body(messages, model, prompt, schemas, adapter_opts)
    req_url = if is_nil(req.url), do: url, else: req.url
    headers = build_headers(provider, api_key, req.headers)

    execute_request(
      req_url,
      req.json_body,
      headers,
      timeout,
      messages,
      pty_session_id,
      chat_session_id,
      opts
    )
  end

  # ── Run context preparation (extracted to reduce CC) ────────────────

  defp prepare_run_context(messages, prompt, opts) do
    # Card pre_context injection
    card_pre = Map.get(opts, :card_pre_context)
    messages = if is_list(card_pre) and card_pre != [] do
      card_pre ++ messages
    else
      messages
    end

    # Card system_prompt merge
    card_sys = Map.get(opts, :card_system_prompt)
    prompt = if card_sys && card_sys != "" do
      prompt <> "\n\n---\n## Role\n" <> card_sys
    else
      prompt
    end

    # Tool filtering
    card_tools = Map.get(opts, :card_tools)
    %{schemas: schemas} = tools()
    {schemas, opts} =
      if is_list(card_tools) do
        allowed = MapSet.new(card_tools)
        filtered = Enum.filter(schemas, fn s -> MapSet.member?(allowed, s.function.name) end)
        {filtered, Map.put(opts, :tools_allowlist, allowed)}
      else
        {schemas, opts}
      end

    {messages, prompt, schemas, opts}
  end

  defp execute_request(
         url,
         json_body,
         headers,
         timeout,
         messages,
         pty_session_id,
         chat_session_id,
         opts
       ) do
    entry = resolve_model_entry(opts)
    provider = Map.get(opts, :provider, entry[:provider] || :openai_compat)
    adapter = adapter_for(provider)

    if System.get_env("EAI_DEBUG_LLM_REQUEST") == "1" do
      require Logger
      Logger.debug("LLM request body", body: inspect(json_body, limit: :infinity, pretty: true))
    end

    start_time = System.monotonic_time(:millisecond)

    :telemetry.execute([:eai, :llm, :request, :start], %{system_time: System.system_time()}, %{
      pty_session_id: pty_session_id
    })

    result = Req.post(url, json: json_body, headers: headers, receive_timeout: timeout)
    duration = System.monotonic_time(:millisecond) - start_time

    handle_http_result(result, duration, messages, pty_session_id, chat_session_id, adapter, opts)
  end

  defp handle_http_result(
         result,
         duration,
         messages,
         pty_session_id,
         chat_session_id,
         adapter,
         opts
       ) do
    case result do
      {:ok, %{status: 200, body: resp_body}} ->
        :telemetry.execute([:eai, :llm, :request, :stop], %{duration_ms: duration}, %{
          pty_session_id: pty_session_id,
          status: :ok
        })

        assistant_msg = adapter.from_response(resp_body)
        handle_response(assistant_msg, messages, pty_session_id, chat_session_id, opts)

      {:ok, %{status: status, body: body}} ->
        :telemetry.execute([:eai, :llm, :request, :stop], %{duration_ms: duration}, %{
          pty_session_id: pty_session_id,
          status: :error
        })

        :telemetry.execute([:eai, :llm, :request, :error], %{duration_ms: duration}, %{
          pty_session_id: pty_session_id,
          reason: "HTTP #{status}",
          body: inspect(body)
        })

        {:error, "HTTP #{status}: #{inspect(body)}", messages}

      {:error, reason} ->
        :telemetry.execute([:eai, :llm, :request, :stop], %{duration_ms: duration}, %{
          pty_session_id: pty_session_id,
          status: :error
        })

        :telemetry.execute([:eai, :llm, :request, :error], %{duration_ms: duration}, %{
          pty_session_id: pty_session_id,
          reason: inspect(reason)
        })

        {:error, reason, messages}
    end
  end

  # ── Response routing ────────────────────────────────────────────────

  defp handle_response(assistant_msg, history, pty_session_id, chat_session_id, opts) do
    history = history ++ [assistant_msg]

    if Message.has_tool_uses?(assistant_msg) do
      handle_tool_calls(assistant_msg, history, pty_session_id, chat_session_id, opts)
    else
      text = Message.text(assistant_msg)
      {:ok, Eai.Utils.sanitize_value(text), history}
    end
  end

  # ── Tool execution loop ─────────────────────────────────────────────

  defp handle_tool_calls(assistant_msg, history, pty_session_id, chat_session_id, opts) do
    %{dispatch: dispatch} = tools()
    allowlist = Map.get(opts, :tools_allowlist)
    dispatch = if allowlist do
      Map.filter(dispatch, fn {name, _} -> MapSet.member?(allowlist, name) end)
    else
      dispatch
    end
    tool_uses = Message.tool_uses(assistant_msg)

    {new_user_messages, should_continue?} =
      Enum.reduce(tool_uses, {[], true}, fn tu, {msgs_acc, cont} ->
        name = tu[:name]
        args = Eai.Utils.sanitize_value(tu[:input])
        tool_use_id = tu[:tool_use_id]

        :telemetry.execute([:eai, :tool, :execute], %{system_time: System.system_time()}, %{
          tool: name,
          pty_session_id: pty_session_id
        })

        content_json =
          try do
            case Map.fetch(dispatch, name) do
              {:ok, mod} -> mod.execute(args, pty_session_id, chat_session_id)
              :error -> Jason.encode!(%{error: "unknown tool: #{name}"})
            end
          rescue
            e ->
              :telemetry.execute([:eai, :tool, :error], %{system_time: System.system_time()}, %{
                tool: name,
                pty_session_id: pty_session_id,
                error: Exception.message(e)
              })

              Jason.encode!(%{error: Exception.message(e)})
          end

        # Check for multimodal_inject
        case Jason.decode(content_json) do
          {:ok, %{"type" => "multimodal_inject", "blocks" => blocks}} ->
            inject_msg = Message.from_inject_blocks(blocks)
            {[inject_msg | msgs_acc], cont}

          {:ok, _} ->
            result_content = [{:text, content_json}]
            tool_msg = Message.new_tool_result(tool_use_id, result_content)
            {[tool_msg | msgs_acc], cont}

          {:error, _} ->
            result_content = [{:text, content_json}]
            tool_msg = Message.new_tool_result(tool_use_id, result_content)
            {[tool_msg | msgs_acc], cont}
        end
      end)

    new_user_messages = Enum.reverse(new_user_messages)
    all_messages =
      (history ++ new_user_messages)
      |> dedup_stale_task_polls()
      |> dedup_stale_subagent_polls()

    if should_continue? do
      run(all_messages, pty_session_id, opts)
    else
      text = Message.text(assistant_msg)
      {:ok, Eai.Utils.sanitize_value(text), history}
    end
  end

  # ── Poll dedup: get_task_result ───────────────────────────────────────
  # Prune stale assistant(tool_use)+user(tool_result) pairs where
  # status == "running". Only the latest running pair survives.
  # Fully independent of get_subagent_result dedup — no shared code path.

  defp dedup_stale_task_polls(all_messages) do
    {clean, _} =
      all_messages
      |> Enum.reverse()
      |> Enum.reduce({[], false}, &reduce_task_poll/2)
    clean
  end

  defp reduce_task_poll(msg, {acc, kept_running}) do
    case classify_task_poll(msg) do
      {:running_user, _tool_use_id} ->
        if kept_running, do: {acc, :skip_assistant}, else: {[msg | acc], true}

      :assistant_poll_tool ->
        if kept_running == :skip_assistant, do: {acc, false}, else: {[msg | acc], kept_running}

      _ ->
        {[msg | acc], kept_running}
    end
  end

  defp classify_task_poll(%{role: :user, content: [{:tool_result, kw}]}) do
    content_str =
      case kw[:content] do
        [{:text, t}] -> t
        _ -> ""
      end

    case Jason.decode(content_str) do
      {:ok, %{"status" => "running"}} -> {:running_user, kw[:tool_use_id]}
      _ -> :other
    end
  end

  defp classify_task_poll(%{role: :assistant, content: content}) do
    has_poll =
      Enum.any?(content, fn
        {:tool_use, kw} -> Keyword.get(kw, :name) == "get_task_result"
        _ -> false
      end)

    if has_poll, do: :assistant_poll_tool, else: :other
  end

  defp classify_task_poll(_), do: :other

  # ── Poll dedup: get_subagent_result ──────────────────────────────────
  # Same pattern as get_task_result, fully independent implementation.
  # A future change to classify_task_poll cannot accidentally affect
  # subagent polling, and vice versa. Explicit duplication over
  # implicit coupling.

  defp dedup_stale_subagent_polls(all_messages) do
    {clean, _} =
      all_messages
      |> Enum.reverse()
      |> Enum.reduce({[], false}, &reduce_subagent_poll/2)
    clean
  end

  defp reduce_subagent_poll(msg, {acc, kept_running}) do
    case classify_subagent_poll(msg) do
      {:running_user, _tool_use_id} ->
        if kept_running, do: {acc, :skip_assistant}, else: {[msg | acc], true}

      :assistant_poll_tool ->
        if kept_running == :skip_assistant, do: {acc, false}, else: {[msg | acc], kept_running}

      _ ->
        {[msg | acc], kept_running}
    end
  end

  defp classify_subagent_poll(%{role: :user, content: [{:tool_result, kw}]}) do
    content_str =
      case kw[:content] do
        [{:text, t}] -> t
        _ -> ""
      end

    case Jason.decode(content_str) do
      {:ok, %{"status" => "running"}} -> {:running_user, kw[:tool_use_id]}
      _ -> :other
    end
  end

  defp classify_subagent_poll(%{role: :assistant, content: content}) do
    has_poll =
      Enum.any?(content, fn
        {:tool_use, kw} -> Keyword.get(kw, :name) == "get_subagent_result"
        _ -> false
      end)

    if has_poll, do: :assistant_poll_tool, else: :other
  end

  defp classify_subagent_poll(_), do: :other

  # ── Model / prompt resolution ────────────────────────────────────────

  defp resolve_model_entry(%{model: name}) when is_atom(name), do: Eai.Models.get!(name)
  defp resolve_model_entry(_opts), do: Eai.Models.default()

  defp resolve_prompt(nil), do: Eai.Prompts.default()[:content]
  defp resolve_prompt(name) when is_atom(name), do: Eai.Prompts.get!(name)[:content]
  defp resolve_prompt(text) when is_binary(text), do: text

  # ── Adapter dispatch ─────────────────────────────────────────────────

  defp adapter_for(:anthropic), do: Eai.Adapter.Anthropic
  defp adapter_for(:openai_compat), do: Eai.Adapter.OpenAI
  defp adapter_for(:converse), do: Eai.Adapter.Converse
  defp adapter_for(_), do: Eai.Adapter.OpenAI

  # ── Header construction ──────────────────────────────────────────────

  defp build_headers(_provider, _api_key, headers) when headers != [], do: headers

  defp build_headers(:anthropic, api_key, []) do
    [
      {"x-api-key", api_key || ""},
      {"anthropic-version", "2023-06-01"},
      {"content-type", "application/json"}
    ]
  end

  defp build_headers(_provider, api_key, []) do
    [authorization: "Bearer #{api_key || ""}"]
  end
end
