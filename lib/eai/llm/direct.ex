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

    %{schemas: schemas} = tools()

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

  # ── Response routing ─────────────────────────────────────────────────

  defp handle_response(assistant_msg, history, pty_session_id, chat_session_id, opts) do
    history = history ++ [assistant_msg]

    if Message.has_tool_uses?(assistant_msg) do
      handle_tool_calls(assistant_msg, history, pty_session_id, chat_session_id, opts)
    else
      text = Message.text(assistant_msg)
      {:ok, Eai.Utils.sanitize_value(text), history}
    end
  end

  # ── Tool execution loop ──────────────────────────────────────────────

  defp handle_tool_calls(assistant_msg, history, pty_session_id, chat_session_id, opts) do
    %{dispatch: dispatch} = tools()
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
    history = dedup_get_task_result_running(history, new_user_messages)

    if should_continue? do
      run(history ++ new_user_messages, pty_session_id, opts)
    else
      text = Message.text(assistant_msg)
      {:ok, Eai.Utils.sanitize_value(text), history}
    end
  end

  # ── get_task_result "running" dedup ─────────────────────────────────


  # When the LLM polls get_task_result multiple times and gets `status: "running"`,
  # only the LATEST poll result matters — the elapsed time in older polls is stale.
  # This function prunes the history: for any new get_task_result tool_result
  # with status "running", it removes the previous assistant+user pair (the old poll
  # and its answer) from the history tail, keeping context clean and small.
  # """

  defp dedup_get_task_result_running(history, new_user_messages) do
    # Check if any new message is a get_task_result "running" result
    has_running? = Enum.any?(new_user_messages, fn msg ->
      msg.role == :user && has_get_task_result_running?(msg)
    end)

    if has_running? do
      prune_last_get_task_result_poll(history)
    else
      history
    end
  end

  defp has_get_task_result_running?(msg) do
    Enum.any?(msg.content, fn
      {:tool_result, [tool_use_id: _, content: content]} ->
        Enum.any?(content, fn
          {:text, text} ->
            case Jason.decode(text) do
              {:ok, %{"status" => "running"}} -> true
              _ -> false
            end
          _ -> false
        end)
      _ -> false
    end)
  end

  # Prune the last assistant+user pair IF the assistant had a get_task_result
  # tool_use and the user result was also "running"
  defp prune_last_get_task_result_poll(history) when length(history) < 2, do: history
  defp prune_last_get_task_result_poll(history) do
    {rest, [user_msg, assistant_msg]} = Enum.split(history, -2)

    if has_get_task_result_tool_use?(assistant_msg) and has_get_task_result_running?(user_msg) do
      rest
    else
      history
    end
  end

  defp has_get_task_result_tool_use?(msg) do
    msg.role == :assistant && Enum.any?(msg.content, fn
      {:tool_use, [tool_use_id: _, name: "get_task_result", input: _]} -> true
      _ -> false
    end)
  end

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
